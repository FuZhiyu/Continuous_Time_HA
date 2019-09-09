%% TWO-ASSET HOUSEHOLD MODEL
% This is the main script for this code repository
% HA model with a liquid asset and an illiquid asset
%
% Prior to running this script:
%
% (1) Set options in the section below. Directory only needs to be set for
% either the server or the local directory, depending on whether
% runopts.Server = 0 or 1
%
% (2) Modify the parameters script 'get_params.m' and make sure that 
% runopts.mode is equal to 'get_params'. Note that all parameter defaults
% are set in the class file code/+setup/Params.m, and get_params.m overrides
% these defaults. Any parameters not in get_params.m are set to their
% defaults. See the attributes of Params.m for a list of all
% parameters.
%
% (3) Set runopts.param_index equal to the index of the parameterization
% you would like to run in the parameters file (1,2,...).
%
% RUNNING ON THE SERVER: To run in batch on the server, use 
% code/batch/server.sbatch as a template. That script sends an array to SLURM 
% that runs all of the requested parameterizations in get_params.m. Output files
% are stored in the Output directory

clear all
warning('off','MATLAB:nearlySingularMatrix')

%% ------------------------------------------------------------------------
% SET OPTIONS
% -------------------------------------------------------------------------

runopts.Server = 1; % sets IterateRho=1,fast=0,param_index=slurm env var
runopts.IterateRho = 1; % if set to zero, the parameter 'rho' is used
runopts.fast = 0; % use small grid for debugging
runopts.mode = 'get_params'; % 'get_params', 'grid_tests', 'chi0_tests', 'chi1_chi2_tests', 'table_tests'
runopts.ComputeMPCS = 1;
runopts.SimulateMPCS = 0; % also estimate MPCs by simulation
runopts.ComputeMPCS_news = 0; % MPCs out of news, requires ComputeMPCS = 1
runopts.SimulateMPCS_news = 0; % NOT CODED

% whether or not to account for b = bmin, a > 0 case where household
% withdraws only enough to consume
runopts.DealWithSpecialCase = 0;  

% Select which parameterization to run from parameters file
% (ignored when runops.Server = 1)
runopts.param_index = 1;

runopts.serverdir = '/home/livingstonb/GitHub/Continuous_Time_HA/';
runopts.localdir = '/Users/Brian-laptop/Documents/GitHub/Continuous_Time_HA/';


%% ------------------------------------------------------------------------
% HOUSEKEEPING, DO NOT CHANGE
% -------------------------------------------------------------------------

if runopts.Server == 0
	runopts.direc = runopts.localdir;
else
	runopts.direc = runopts.serverdir;
	runopts.param_index = str2num(getenv('SLURM_ARRAY_TASK_ID'));
    
	runopts.fast = 0;
	runopts.IterateRho = 1;
end

% check that specified directories exist
if ~exist(runopts.direc,'dir')
    error([runopts.direc ' does not exist'])
end
    
% for saving
runopts.suffix = num2str(runopts.param_index);

% directory to save output, and temp directory
runopts.savedir = [runopts.direc 'output/two_asset/'];

% temp directory
runopts.temp = [runopts.direc 'temp/two_asset/'];

addpath([runopts.direc,'code']);
addpath([runopts.direc,'code/factorization_lib']);

mkdir(runopts.temp);
mkdir(runopts.savedir);
addpath(runopts.temp);
addpath(runopts.savedir);

cd(runopts.direc)

%% ------------------------------------------------------------------------
% CALL MAIN FUNCTION FILE
% -------------------------------------------------------------------------
tic
[stats,p] = main_two_asset(runopts);
toc
