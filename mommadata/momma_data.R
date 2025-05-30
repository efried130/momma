# Imports
library(reticulate)
library(optparse)

# Local
source("/app/mommadata/input_data.R")
source("/app/mommadata/output_data.R")
source("/app/mommadata/momma/function.find.rating.break.R")
source("/app/mommadata/momma/function.find.zero.flow.stage.R")
source("/app/mommadata/momma/function.constrain.momma.nb.x.R")
source("/app/mommadata/momma/function.calibrate.Qmean.R")
source("/app/mommadata/momma/function.MOMMA.confluence.swot.v3.3.2.R")

# example local deployment
#sudo docker run -v /mnt/input/:/mnt/data/input -v /mnt/flpe/momma:/mnt/data/output -v ~/.aws:/root/.aws momma -r /mnt/data/input/reaches.json -m 3 -b confluence-sos/unconstrained/0000 -i 5

PYTHON_EXE = "/usr/bin/python3"
PYTHON_FILE = "/app/sos_read/sos_read.py"
TMP_PATH = "/tmp"

#' Identify reach and locate SWOT and SoS files.
#'
#' Download SoS file to TEMP_PATH and return full path to download.
#'
#' @param input_dir string path to input directory
#' @param reaches_json name of json reach file
#'
#' @return list of swot file and sos file
get_reach_files <- function(input_dir, reaches_json, index, bucket_key){

  # Get reach data from index
  json_data <- rjson::fromJSON(file=file.path(input_dir, reaches_json))[[index]]

  if (bucket_key != "") {
    # Download the SoS file and reference the file path
    use_python(PYTHON_EXE)
    source_python(PYTHON_FILE)

    sos_filepath <- file.path(TMP_PATH, json_data$sos)
    download_sos(bucket_key, sos_filepath)
    reach_list <- list(reach_id = json_data$reach_id,
                      swot_file = file.path(input_dir, "swot", json_data$swot),
                      sos_file = sos_filepath)
  } else {
    reach_list <- list(reach_id = json_data$reach_id,
                      swot_file = file.path(input_dir, "swot", json_data$swot),
                      sos_file = file.path(input_dir, "sos", json_data$sos))
  }

  return(reach_list)

}

#' Create placeholder MOMMA list that will be used to store results.
#'
#' @param nt number of time steps
#'
#' @return list of data and diagnostics
create_momma_list <- function(nt) {
  # Create empty vector placeholder
  nt_vector <- rep(NA, nt)

  # Create empty data list
  data = list(stage = nt_vector,
              width = nt_vector,
              slope = nt_vector,
              Qgage = nt_vector,
              seg = nt_vector,
              n = nt_vector,
              nb = nt_vector,
              x = nt_vector,
              Y = nt_vector,
              v = nt_vector,
              Q = nt_vector,
              Q.constrained = nt_vector)

  # Create empty diagnostics list
  output = list(gage_constrained = NA,
                input_Qm_prior = NA,
                input_Qb_prior = NA,
                input_Yb_prior = NA,
                input_known_ezf = NA,
                input_known_bkfl_stage = NA,
                input_known_nb_seg1 = NA,
                input_known_x_seg1 = NA,
                Qgage_constrained_nb_seg1 = NA,
                Qgage_constrained_x_seg1 = NA,
                input_known_nb_seg2 = NA,
                input_known_x_seg2 = NA,
                Qgage_constrained_nb_seg2 = NA,
                Qgage_constrained_x_seg2 = NA,
                n_bkfl_Qb_prior = NA,
                n_bkfl_slope = NA,
                vel_bkfl_Qb_prior = NA,
                Froude_bkfl_diag_Smean = NA,
                width_bkfl_solved_obs = NA,
                depth_bkfl_solved_obs = NA,
                depth_bkfl_diag_Wb_Smean = NA,
                zero_flow_stage = NA,
                bankfull_stage = NA,
                width_stage_corr = NA,
                Qmean_prior = NA,
                Qmean_momma = NA,
                Qmean_momma.constrained = NA)

  # Return placeholder list
  return(list(data = data, output = output))
}

#' Run MOMMA
#'
#' Write output from MOMMA execution on each reach data input.
#'
#' Commandline arguments (optional):
#' name of txt file which contains reach identifiers on each line
run_momma <- function() {

  # I/O directories
  input_dir <- file.path("/mnt", "data", "input")
  output_dir <- file.path("/mnt", "data", "output")

  option_list <- list(
    make_option(c("-i", "--index"), type = "integer", default = -256, help = "Index to run on"),
    make_option(c("-b", "--bucket_key"), type = "character", default = "", help = "Bucket key to find the sos"),
    make_option(c("-r", "--reaches_json"), type = "character", default = NULL, help = "Name of reaches.json"),
    make_option(c("-m", "--min_nobs"), type = "character", default = NULL, help = "Minimum number of observations for a reach to have to be considered valid"),
    make_option(c("-c", "--constrained"), action = "store_true", default = FALSE, help = "Indicate constrained run")
  )

  opt_parser <- OptionParser(option_list = option_list)
  opts <- parse_args(opt_parser)
  bucket_key <- opts$bucket_key
  reaches_json <- opts$reaches_json
  min_nobs <- as.numeric(opts$min_nobs)
  constrained <- opts$constrained

  # Parse index
  index <- opts$index

  # Check if we are running via env variable...
  if (index == -256){
    index <- strtoi(Sys.getenv("AWS_BATCH_JOB_ARRAY_INDEX"))
  }

  index <- index + 1    # Add 1 to AWS 0-based index


  print(paste("bucket_key: ", bucket_key))
  print(paste("index: ", index))
  print(paste("reaches_json: ", reaches_json))
  print(paste("min_nobs: ", min_nobs))
  print(paste("constrained: ", constrained))

  io_data <- get_reach_files(input_dir, reaches_json, index, bucket_key)
  print(paste("reach_id: ", io_data$reach_id))
  print(paste("swot_file: ", io_data$swot_file))
  print(paste("sos_file: ", io_data$sos_file))

  # Get SWOT and SoS input data
  reach_data <- get_input_data(swot_file = io_data$swot_file,
                               sos_file = io_data$sos_file,
                               reach_id = io_data$reach_id,
                               min_nobs = min_nobs,
                               constrained = constrained)

  # Create empty placeholder list
  momma_results <- create_momma_list(length(reach_data$nt))
  # Run MOMMA on valid input reach data
  if (reach_data$valid == TRUE) {
    print('running momma')
    momma_results <- momma(stage = reach_data$wse,
                           width = reach_data$width,
                           slope = reach_data$slope2,
                           Qb_prior = reach_data$Qb,
                           Qm_prior = reach_data$Qm,
                           Yb_prior = reach_data$db,
                           Qgage = reach_data$Qgage)
  }else{
    print('decided not to run')
  }

  # Write posteriors to netCDF
  write_netcdf(reach_data, momma_results, output_dir)
}

run_momma()
