# Creates the data files at the Census tract level using 2017 LODES data, 
# subtracting jobs over 40k from all jobs. BLS or Washington unemployment data is available.  

# load libraries
library(tidyverse)
library(sf)
library(testit)

#----Set Parameters----------------------------------------------------
# choose which dataset to use ; should be either `bls`, `wa`, `ny`, or `all_states`
dataset <- "wa"


#----Read in Data----------------------------------------------------

# read in industry to lodes xwalk, to put names to lodes industries
lehd_types <- read_csv("data/raw-data/small/lehd_types.csv")

# read in geography crosswalk from trct to county to cbsa
trct_cty_cbsa_xwalk <- read_csv("data/processed-data/tract_county_cbsa_xwalk.csv")


# Read in % change employement estimates from WA or BLS
prep_employment_join <- function(df){
  df %>% 
    mutate(lodes_var = tolower(lodes_var)) %>% 
    select(lodes_var, percent_change_employment)
}

if(dataset == "wa"){
  
 job_loss_estimates <- read_csv("data/processed-data/job_change_wa_most_recent.csv") %>% 
   prep_employment_join()
  
} else if(dataset == "bls"){
  
  #read in most recent file and prepare for join
  job_loss_estimates <- read_csv("data/processed-data/job_change_bls_most_recent.csv") %>% 
    prep_employment_join()
    
  
} else {
  #if incorrect dataset value
  stop("incorrect value for `dataset`: should be `wa` or `bls`")
}


lodes_joined <- read_csv("data/processed-data/lodes_joined.csv")

#----Generate job loss estimates for all tracts-----------------------------------

# Generate job loss estimates for each industry across all tracts. 

job_loss_wide = lodes_joined %>% 
  # join lodes total employment data to % change in 
  # employment estimates from WA or BLS
  left_join( job_loss_estimates, 
          by = c("variable" = "lodes_var"))  %>% 
  # keep only industry variables
  filter(startsWith(variable, "cns")) %>% 
  # multiply number of jobs in industry by the % change unemployment for that industry
  mutate(job_loss_in_industry = value * -1 * percent_change_employment,
         ind_var = paste0("X", str_remove(variable, "cns"))) %>% 
  select(-value, -year, -percent_change_employment, -variable) %>%
  # pvit wide to go from row=tract-industry  to row=tract
  pivot_wider(names_from = ind_var, values_from = job_loss_in_industry, id_cols = trct) %>% 
  # sum all jobs lost across all industries for total job loss per tract
  mutate(X000 =(.)%>% select(starts_with("X")) %>% rowSums(na.rm=TRUE)) %>% 
  # append county/cbsa info for each tract
  left_join(trct_cty_cbsa_xwalk, by = c("trct" = "GEOID")) %>% 
  select(trct, county_fips, county_name, cbsa, cbsa_name, everything()) 
# Note: every row of job_loss_wide is a tract

# The LODES data has one tract not found in the master 2018 Census tract file.
# This is tract 12057980100, which is in Florida and seems to be mostly water.
# For now we exlcude this tract from the analysis

# Display problematic tract
job_loss_wide %>% 
  group_by(trct) %>% 
  summarize(any_na = any(is.na(county_fips))) %>% 
  filter(any_na)

# Discard problematic tract 
job_loss_wide = job_loss_wide %>%
                filter(trct != "12057980100")




#----Append tract geographies to job loss estimates-----------------------------------

# read in tract geography
my_tracts <- st_read("data/processed-data/tracts.geojson") %>% 
  mutate_if(is.factor, as.character) %>% 
  # filter out tracts in Puerto Rico
  filter(!startsWith(GEOID, "72")) %>% 
  # filter out tracts that are only water
  filter(substr(GEOID, 6, 7) != "99")

# join data to tract spatial information
job_loss_wide_sf <- left_join(my_tracts %>% select(GEOID), 
                              job_loss_wide, 
                              by = c("GEOID" = "trct")) 

# The 2018 Census tract file has one tract not found in the LODES data
# This is tract 12086981000 near Miami Beach in Florida & has a population 
# of 62. For now we exlcude this tract from the analysis
job_loss_wide_sf <- job_loss_wide_sf %>% 
                    filter(GEOID != "12086981000")

# Check that the tracts contianed in job_loss_wide are the same after
# adding spatial info
assert("job_loss_wide_sf has a different number of rows that job_loss_wide",
       nrow(job_loss_wide_sf) == nrow(job_loss_wide))
assert("job_loss_wide_sf has differnt GEOIDS compared to job_loss_wide",
       all.equal(job_loss_wide %>% 
         arrange(trct) %>% 
         pull(trct),
       job_loss_wide_sf %>% 
         arrange(GEOID) %>% 
         pull(GEOID)))


#----Write out job loss estimates for tracts-----------------------------------

# remove extraneous variables and write out
# job_loss_by_tract.geojson which is list of all tracts,
# thier cbsa (can be NA) and job loss estimates by sector

geo_file_name <- "data/processed-data/s3_final/job_loss_by_tract.geojson"

job_loss_wide_sf %>%
  select(-c(county_fips, 
            county_name,
            cbsa_name)) %>% 
  # round jobs by industry to 0.1 (to decrease output file size)
  mutate_at(.vars = vars(X01:X20), ~round(., digits = 1)) %>% 
  # round total jobs lost to integer for reader
  # for reader understandability (What is 1.3 jobs?)
  mutate(X000 = round(X000)) %>%
  #write out geography
  st_write(geo_file_name, delete_dsn = TRUE)

#----Aggregate and write out job loss estimates for counties-----------------------------------

county_sums <- job_loss_wide_sf %>%
  # drop spatial features
  st_drop_geometry() %>%
  # ensure no missing counties
  filter(!is.na(county_fips)) %>%
  # cast county as character to avoid warnings
  mutate(county_fips = as.character(county_fips)) %>% 
  # group by the county
  group_by(county_fips) %>% 
  # aggregate industry job loss values to county
  summarise_at(.vars = vars(starts_with("X")), ~sum(.)) %>% 
  # ungroup data
  ungroup() %>% 
  # write out delimited
  write_csv("data/processed-data/county_sums.csv")


#----Aggregate and write out job loss estimates for cbsas-----------------------------------
cbsa_sums <- job_loss_wide_sf %>% 
  # drop spatial features
  st_drop_geometry() %>%
  # ensure no missing cbsas
  filter(!is.na(cbsa)) %>%
  # cast cbsa as character to avoid warning
  mutate(cbsa= as.character(cbsa)) %>% 
  # group by the cbsa
  group_by(cbsa) %>% 
  # aggregate industry job loss values to cbsa
  summarise_at(.vars = vars(starts_with("X")), ~sum(.)) %>% 
  # write out delimited
  write_csv("data/processed-data/cbsa_sums.csv")


