function [fData] = pf2_updateCurrentDevice(fData,cfgFilePath)
% PF2_UPDATECURRENTDEVICE Synchronize device configuration with fNIRS data
%
% Updates the global PF2 and setF structures to reflect the current device
% configuration. Loads device configuration files as needed, extracts channel
% and wavelength information, and computes timing data from the raw signal.
% This function ensures consistency between the loaded fNIRS data and the
% device settings used for processing.
%
% Reference:
%   Internal pf2 implementation for device configuration management.
%
% Syntax:
%   fData = pf2_updateCurrentDevice(fData)
%   fData = pf2_updateCurrentDevice(fData, cfgFilePath)
%
% Inputs:
%   fData       - fNIRS data structure containing raw data and metadata
%                 Must include .raw field [T x C double] and optionally
%                 .info.probename for automatic device detection.
%   cfgFilePath - Path to device configuration file (default: auto-detect)
%                 Must be a .cfg file from the devices/ directory.
%                 If empty or invalid, prompts user via GUI selection.
%
% Outputs:
%   fData - Updated fNIRS structure with additional fields:
%           .probeInfo - Probe geometry information
%           .fs        - Sampling frequency in Hz
%           .time      - Time vector [T x 1]
%           .sampleTime - Sample indices [1 x T]
%
% Algorithm:
%   1. Clear existing channel/wavelength sets in PF2 global
%   2. Load or validate device configuration file
%   3. Extract channel numbers, wavelengths, and source-detector info
%   4. Compute timing information from raw data or config defaults
%
% Example:
%   % Update device settings from data's embedded probe name
%   data = pf2.import.importNIR('myfile.nir');
%   data = pf2_base.pf2_updateCurrentDevice(data);
%
%   % Explicitly specify device configuration
%   data = pf2_base.pf2_updateCurrentDevice(data, 'fNIR_Devices_fNIR2000.cfg');
%
% Notes:
%   - Uses global variables PF2 and setF for state management
%   - Multiple probes may not be fully supported (warning issued)
%   - Assumes merged probe layout with unique channel numbers
%
% See also: loadDeviceCfg, loadProbeInfo, pf2_initialize

global setF
global PF2

PF2.curChSet=[];
PF2.curWvSet=[];
PF2.curSDSet=[];
PF2.curProbeInd=[];


if(nargin>1&&isempty(cfgFilePath)||~contains(cfgFilePath,'.cfg'))&&(~isempty(fData)) %if nothing, invalid, or no data
    
    warning('Missing or invalid configuration file path\n')
    
    disp('No device specified. Please load device configuration');
    pf2_base.loadDeviceCfg();
    if(~isfield(setF,'device'))
        error('pf2_base:pf2_updateCurrentDevice:noValidDevices', 'No valid devices selected');
    end
    
elseif(nargin>1&&~isempty(cfgFilePath)) 
    
    if(pf2_base.isnestedfield(setF,'device.cfg.Info.CfgName')) % look to see if they match,...
            
        curProbeName=sprintf('%s.cfg',setF.device.cfg.Info.CfgName);
        
        if(~strcmp(curProbeName,cfgFilePath)) %if they do don't bother loading
            pf2_base.loadDeviceCfg(cfgFilePath,true);
        end
    else
        pf2_base.loadDeviceCfg(cfgFilePath,true);
    end
elseif(nargin==1)
    
    if(pf2_base.isnestedfield(fData,'info.probename')) % look to see if they match,...
            
        dataProbeName=sprintf('%s.cfg',fData.info.probename);
        
        if(pf2_base.isnestedfield(setF,'device.cfg.Info.CfgName')) % look to see if they match,...
            if(~strcmp(dataProbeName,(setF.device.cfg.Info.CfgName)) %if they do don't bother loading
                    pf2_base.loadDeviceCfg(dataProbeName,true);
            end
        else
            pf2_base.loadDeviceCfg(dataProbeName,true);
        end
    else
        warning('Missing or invalid configuration file path\n')
    
        disp('No device specified. Please load device configuration');
        pf2_base.loadDeviceCfg();
        if(~isfield(setF,'device'))
            error('pf2_base:pf2_updateCurrentDevice:noValidDevices', 'No valid devices selected');
        end
    end
    
end


if(length(setF.device.Probe)==1)
    PF2.mergedProbe=true;
    fData.probeInfo=setF.device{1};
else
    PF2.mergedProbe=true;
    warning('Multiple Probes may not be fully supported');
end

if(PF2.mergedProbe) %All channel numbers are unique for merged probes
    for i =1:length(setF.device.Probe)
        PF2.curChSet=[PF2.curChSet,setF.device.Probe{i}.ChannelNumbers];
        PF2.curProbeInd=[PF2.curProbeInd,i*length(setF.device.Probe{i}.ChannelNumbers)];
    
        PF2.curWvSet=[PF2.curWvSet,setF.device.Probe{i}.Wavelength];
        PF2.curSDSet=[PF2.curSDSet,setF.device.Probe{i}.SD];
    end
    PF2.timeIndex=find(PF2.curChSet==0);
    if(isempty(PF2.timeIndex))
        % Expected for devices whose raw data has no time column (e.g.
        % NIRx), so it is shown once per session
        persistent noTimeColumnNoted
        if(isempty(noTimeColumnNoted))
            noTimeColumnNoted=true;
            warning('pf2:updateCurrentDevice:noTimeColumn', ...
                ['Time column could not be found, assuming each row is a sample. ', ...
                 '(This note is shown once per session.)']);
        end
        PF2.timeIndex=0;
    end
else
    error('pf2_base:pf2_updateCurrentDevice:notImplemented', 'Not yet implemented for seperate probe data,\nAssumes concatenated datasets with unique channels in the config file'); 
end

[~,i]=unique(PF2.curChSet);
PF2.curChList=PF2.curChSet(i);


if(PF2.mergedProbe) %All channel numbers are unique for merged probes  
    
    data=fData.raw;
    
    if(~isempty(data))
        if(isfield(fData,'time')&&~isempty(fData.time))
            fData.fs=1./median(diff(fData.time));
            fData.sampleTime=1:length(data(:,1));
        elseif(PF2.timeIndex==0)
            fData.sampleTime=1:length(data(:,1));
            fData.time=(fData.sampleTime-1)./fData.device.Info.DefaultSamplingRate;
            fData.fs=fData.device.Info.DefaultSamplingRate;
        elseif(setF.device.Info.TimeIsSampleCount==1)
            fData.sampleTime=data(:,PF2.timeIndex);
            fData.time=(fData.sampleTime-1)./fData.device.Info.DefaultSamplingRate;
            fData.fs=fData.device.Info.DefaultSamplingRate;
        else
            fData.sampleTime=1:length(data(:,1));
            fData.time=data(:,PF2.timeIndex);
            fData.fs=1./median(diff(fData.time));
        end
    elseif(isfield(data,'time')&&~isempty(fData.time))  %If time exists
        fData.sampleTime=1:length(fData.time);
        fData.fs=1./median(diff(fData.time));
    elseif(~isempty(fData.stage{4})) %try to calculate from oxy data
        data=fData.stage{4};
        if(isfield(fData,'time')&&~isempty(fData.time))
            fData.fs=1./median(diff(fData.time));
            fData.sampleTime=1:length(data(:,1));
        elseif(PF2.timeIndex==0)
            fData.sampleTime=1:length(data.HbO(:,1));
            fData.time=(fData.sampleTime-1)./fData.device.Info.DefaultSamplingRate;
            fData.fs=fData.device.Info.DefaultSamplingRate;
        elseif(fData.device.Info.TimeIsSampleCount==1)
            fData.sampleTime=data.HbO(:,PF2.timeIndex);
            fData.time=(fData.sampleTime-1)./fData.device.Info.DefaultSamplingRate;
            fData.fs=fData.device.Info.DefaultSamplingRate;
        else
            fData.sampleTime=1:length(data.HbO(:,1));
            fData.time=data.HbO(:,PF2.timeIndex);
            fData.fs=1./median(diff(fData.time));
        end
    end

else
   error('pf2_base:pf2_updateCurrentDevice:notImplemented', 'Not Yet Implemented for seperate probe data,\nAssumes concatenated datasets with unique channels in the config file'); 
end

% A counter time base (COBI .nir) has its rate from the fitted counter tick
if(isfield(fData,'fs')&&isfield(fData,'info')&&isstruct(fData.info)&&isfield(fData.info,'timebase')&&isfield(fData.info.timebase,'fs'))
    fData.fs=fData.info.timebase.fs;
end
end
