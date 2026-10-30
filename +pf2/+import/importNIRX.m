function [fNIR] = importNIRX(folderDIR,channelCheck,varargin)
% IMPORTNIRX Import fNIRS data from NIRx system recordings
%
% Reads fNIRS data from NIRx systems (NIRScout, NIRSport) which store data
% across multiple files including wavelength data (.wl1, .wl2), header
% information (.hdr), and optionally .nirs files containing probe geometry.
% Supports both legacy file formats and newer JSON-based configurations.
%
% Reference:
%   Internal pf2 implementation for NIRx file format.
%   NIRx Medical Technologies, LLC. https://nirx.net/
%
% Syntax:
%   fNIR = pf2.import.importNIRX()
%   fNIR = pf2.import.importNIRX(folderDIR)
%   fNIR = pf2.import.importNIRX(folderDIR, channelCheck)
%
% Inputs:
%   folderDIR    - Path to NIRx recording folder or .hdr/.nirs file [char | string]
%                  If omitted or empty, a file selection dialog opens.
%                  Can be either:
%                    - Full path to the .hdr or .nirs file
%                    - Path to folder containing NIRx recording files
%   channelCheck - Run channel quality check GUI after import (default: true)
%                  Set to false to skip interactive quality assessment.
%
% Outputs:
%   fNIR - Standard pf2 fNIRS data structure containing:
%          .raw       - Raw intensity data [T x C double]
%          .time      - Time vector in seconds [T x 1 double]
%          .fs        - Sampling frequency in Hz [double]
%          .markers   - Event marker table (.Time, .Code, .Duration, .Amplitude)
%          .fchMask   - Channel quality mask [1 x C: 1=good, 0=bad]
%          .info      - Recording metadata and probe information
%          .probeinfo - Device and probe geometry structure
%          .Aux       - Auxiliary data from .nirs file (if available)
%
% Algorithm:
%   1. Locate all relevant files in the recording folder
%   2. Parse .hdr file for sampling rate, wavelengths, and channel config
%   3. Load wavelength data from .wl1, .wl2 files (or .nirs file)
%   4. Extract probe geometry from .nirs file or JSON config
%   5. Parse markers from .hdr or .tri files
%   6. Generate 2D probe layout from 3D positions
%
% Example:
%   % Import with file dialog
%   data = pf2.import.importNIRX();
%
%   % Import from specific folder
%   data = pf2.import.importNIRX('/path/to/recording/2024-01-15_001.hdr');
%
%   % Import without channel check for batch processing
%   data = pf2.import.importNIRX(folderPath, false);
%
% Notes:
%   - Supports NIRSport and NIRScout systems
%   - Automatically detects short-separation channels (SD < 2cm)
%   - Optode positions are stored in mm (converted from the .nirs SpatialUnit);
%     source-detector distances are stored in cm
%   - Recording start (.t0) and device model are read from the .hdr GeneralInfo
%     (Device, or else Device ID mapped to the model name). t0 has no time
%     zone; pass 'TimeZone' to pf2.export.asSNIRF to write absolute times.
%   - 3D optode positions are kept as recorded; the 2D layout is a top view
%     (anterior up, right on the right): the planar positions when the
%     montage is flat, otherwise a projection of the 3D positions about the
%     vertex
%   - All-zero aux columns (no aux input connected) are dropped
%   - Subject demographics read from _description.json if available
%   - Changes working directory during import, then restores original
%
% See also: pf2.import.importSNIRF, pf2.import.importNIR, pf2.import.importHitachiMES

pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

if(nargin<2)
   channelCheck=true;
   forceChannelCheck=false;
else
   forceChannelCheck=true;
end

channelCheckVersion=pf2_base.channelCheckVersion();
for vi_=1:2:numel(varargin)
    if ischar(varargin{vi_}) && strcmpi(varargin{vi_},'ChannelCheckVersion')
        channelCheckVersion=varargin{vi_+1};
    end
end

includeSSchannels=true;

buildProbeLayout=true;

if nargin < 1 || isempty(folderDIR)
   [fname,pathname] = uigetfile({'*.hdr;*.nirs';'*.*'},'Open NIRX Config file');
   if isequal(fname,0)   % selection cancelled
       fNIR = [];
       return;
   end
   folderDIR = fullfile(pathname,fname);
elseif ~ischar(folderDIR) && ~isstring(folderDIR)
  error('pf2:importNIRX:badInput', 'Input must be a string representing a filename');
end
folderDIR = char(folderDIR);

% If the input is a recording FOLDER (the documented usage) rather than a
% file, locate the NIRx config file (.hdr, else .nirs) inside it. Without this
% guard a folder path is split on the separator and the code cd's to the
% PARENT, so the .wl1/.wl2/.hdr are never found.
if isfolder(folderDIR)
    hdr = dir(fullfile(folderDIR, '*.hdr'));
    if isempty(hdr), hdr = dir(fullfile(folderDIR, '*.nirs')); end
    if isempty(hdr)
        error('pf2:importNIRX:noHdrInFolder', ...
            'No .hdr or .nirs config file found in folder ''%s''.', folderDIR);
    end
    folderDIR = fullfile(folderDIR, hdr(1).name);
end

% Normalize Windows backslashes so the single split logic below is portable.
folderDIR = strrep(folderDIR, '\', '/');

% Always derive pathname/filename from the (now full) folderDIR path so the
% file-dialog and direct-argument cases follow the same code path below.
folderDIRparts=strsplit(folderDIR,'/');
filename=folderDIRparts{end};
pathname=folderDIR(1:end-length(filename));

curdir=cd;
cdCleanup = onCleanup(@() cd(curdir));
if(~isempty(pathname))
    cd(pathname);
end
d=dir;

if(length(d)>2)
    files=cell(length(d)-2,2);
else
    error('pf2:importNIRX:noFilesFound', 'No files found');
end

x=0;
for i=1:length(d)
    if(~d(i).isdir)
        x=x+1;
        files(x,1)={d(i).name};
        if ~isempty(strfind(files{x,1},'.wl'))
            files(x,2)={'wavelength'};
        end
        if ~isempty(strfind(files{x,1},'.inf'))
            files(x,2)={'demographics'};
        end
        if ~isempty(strfind(files{x,1},'.hdr'))
            files(x,2)={'info'};
        end
        if ~isempty(strfind(files{x,1},'_description.json'))
            files(x,2)={'j_description'};
        end
        if ~isempty(strfind(files{x,1},'_config.json'))
            files(x,2)={'j_info'};
        end
        if ~isempty(strfind(files{x,1},'_lsl.tri'))
            files(x,2)={'markers'};
        end
        
        if ~isempty(strfind(files{x,1},'.nirs'))
            files(x,2)={'nirs_file'};
        end
    end
end
clear x dir;

fNIR=[];
fNIR.raw=[];
wvCell=cell(0);

device=[];

for i=1:size(files,1)
    filename=files{i,1};
    if(strcmp(files{i,2},'wavelength'))
        
        strs=strsplit(filename,'.');
        wvNum=str2double(strs{end}(3));
        [wvCell{wvNum}] = dlmread(filename,' ');
    end
    
    if(strcmp(files{i,2},'nirs_file'))
        filenameParts=strsplit(filename,'.');
        fileroot=filenameParts{1};
        probeInfo=load(filename,'-mat');
        
        device=[];
        if(isfield(probeInfo,'t'))
            fNIR.time=[probeInfo.t(:)];
            
            fNIR.fs=1/nanmedian(diff(fNIR.time));
            device.Info.TimeIsSampleCount=0;
        end
        if(isfield(probeInfo,'d'))
            fNIR.raw=[probeInfo.d]; % don't load t in data
        end
        if(isfield(probeInfo,'s'))
            mrk=[];
            for mrkID=1:size(probeInfo.s,2)
                curMrkTime(:,1)=fNIR.time(probeInfo.s(:,mrkID)==1);
                curMrkTime(:,2)=mrkID;
                mrk=[mrk;curMrkTime];
            end
            [~,sortIdx]=sort(mrk(:,1));
            fNIR.markers=mrk(sortIdx,:);
            fNIR.markers = pf2_base.normalizeMarkers(fNIR.markers);
        end
        % Keep only aux columns that were recorded (NIRStar writes an
        % all-zero column when no aux input is connected)
        if(isfield(probeInfo,'aux')&&~isempty(probeInfo.aux))
            auxData=probeInfo.aux(:,any(probeInfo.aux~=0,1));
            if(~isempty(auxData))
                fNIR.Aux.NIRx=auxData;
            end
        end
        
        % Keep optode positions in mm, the toolbox-wide coordinate unit
        % (loadDeviceCfg, importSNIRF); SD distances below are stored in cm.
        posScale=1;
        if(isfield(probeInfo.SD,'SpatialUnit'))
            switch(lower(strtrim(probeInfo.SD.SpatialUnit)))
                case 'cm'
                    posScale=10;
                case 'm'
                    posScale=1000;
            end
        end
        probeInfo.SD.SrcPos=probeInfo.SD.SrcPos*posScale;
        probeInfo.SD.DetPos=probeInfo.SD.DetPos*posScale;
        [srcPos2D,detPos2D]=layout2D(probeInfo.SD.SrcPos,probeInfo.SD.DetPos);
        
        probeNums=unique(probeInfo.SD.MeasList(:,3)); % I THINK
        
        probeIdx=probeInfo.SD.MeasList(:,3);
        
        
        %device=pf2_base.external.INI();
        
        %%device.cfg=[];
        %device.cfg.Info=[];
        
        
        device.cfg=pf2_base.external.INI();
        device.Info.CfgName='generated NIRX file';
        
        % Name and sampling rate are filled from the .hdr after all files are read
        device.Info.Name='NIRx';
        device.Info.Manufacturer='NIRx';
        device.Info.CoordinateUnits='mm';
        device.Info.NumberProbes=length(probeNums);
        device.Info.RawMax=1;
        device.Info.RawMin=0;
        device.Info.NumberChannels=0;
        
        
        for p=1:length(probeNums)
            
            curProbeIdx=probeIdx==p;
        
            device.Probe{p}=[];

            
            
            
            % SrcPos*/DetPos* X/Y/Z hold the 2D layout (Z=0); 3D stays in *Pos3D
            device.Probe{p}.SrcPosX=srcPos2D(:,1);
            device.Probe{p}.SrcPosY=srcPos2D(:,2);
            device.Probe{p}.SrcPosZ=zeros(size(srcPos2D,1),1);
            device.Probe{p}.DetPosX=detPos2D(:,1);
            device.Probe{p}.DetPosY=detPos2D(:,2);
            device.Probe{p}.DetPosZ=zeros(size(detPos2D,1),1);
            
            
            device.Probe{p}.SrcPos3D=probeInfo.SD.SrcPos;
            device.Probe{p}.DetPos3D=probeInfo.SD.DetPos;

            device.Probe{p}.TableSD=table();
            device.Probe{p}.TableCh=table(); % Map for raw probe data
            
            device.Probe{p}.TableCh.ColNumber=[1:length(probeInfo.SD.MeasList(:,1))]';

            [~,~,uOpt]=unique(probeInfo.SD.MeasList(:,[1:2]),'rows');
            device.Probe{p}.TableCh.OptodeNumber=uOpt;
            device.Probe{p}.TableCh.isTime=device.Probe{p}.TableCh.OptodeNumber==0;
            device.Probe{p}.TableCh.isMarker=device.Probe{p}.TableCh.OptodeNumber<0|isnan(device.Probe{p}.TableCh.OptodeNumber);
            device.Probe{p}.TableCh.OptodeNumber(device.Probe{p}.TableCh.OptodeNumber<1)=nan;
            
            
            device.Probe{p}.TableCh.Wavelength=probeInfo.SD.Lambda(probeInfo.SD.MeasList(:,4))';
            device.Probe{p}.TableCh.SourceIndex(:)=probeInfo.SD.MeasList(:,1);
            device.Probe{p}.TableCh.DetectorIndex(:)=probeInfo.SD.MeasList(:,2);

            % Flag real-channel columns (the OD->Hb stage selects data(:,isCh)).
            % NIRX raw carries no time/marker columns, so every measurement is a
            % channel; dark columns are those with no valid wavelength. Match the
            % toolbox-wide convention (importOxy3, loadDeviceCfg): isCh EXCLUDES
            % dark columns, so downstream consumers (processStageOD2Hb, qc.sci,
            % dot.channelGeometry) never treat a dark column as a measurement.
            validCh=~isnan(device.Probe{p}.TableCh.OptodeNumber);
            device.Probe{p}.TableCh.isDark=(isnan(device.Probe{p}.TableCh.Wavelength) ...
                | device.Probe{p}.TableCh.Wavelength==0) & validCh;
            device.Probe{p}.TableCh.isCh=validCh(:) & ~device.Probe{p}.TableCh.isDark(:);

            device.Probe{p}.SrcPos=table();
            device.Probe{p}.SrcPos.x_2d=device.Probe{p}.SrcPosX(:);
            device.Probe{p}.SrcPos.y_2d=device.Probe{p}.SrcPosY(:);
            device.Probe{p}.SrcPos.z_2d=device.Probe{p}.SrcPosZ(:);
            device.Probe{p}.SrcPos.x=probeInfo.SD.SrcPos(:,1);
            device.Probe{p}.SrcPos.y=probeInfo.SD.SrcPos(:,2);
            device.Probe{p}.SrcPos.z=probeInfo.SD.SrcPos(:,3);
            
            
            device.Probe{p}.DetPos=table();
            device.Probe{p}.DetPos.x_2d=device.Probe{p}.DetPosX(:);
            device.Probe{p}.DetPos.y_2d=device.Probe{p}.DetPosY(:);
            device.Probe{p}.DetPos.z_2d=device.Probe{p}.DetPosZ(:);
            device.Probe{p}.DetPos.x=probeInfo.SD.DetPos(:,1);
            device.Probe{p}.DetPos.y=probeInfo.SD.DetPos(:,2);
            device.Probe{p}.DetPos.z=probeInfo.SD.DetPos(:,3);
            
          
            

           
            device.Probe{p}.dI=probeInfo.SD.MeasList(curProbeIdx,2);
            device.Probe{p}.sI=probeInfo.SD.MeasList(curProbeIdx,1);
            
            SDpairs=[device.Probe{p}.sI,device.Probe{p}.dI];
            [uPairs,uPairUnsorted,uPairIdx]=unique(SDpairs,'rows');
            uPairs=SDpairs(uPairUnsorted,:);
            
            for opt=1:size(uPairs,1)
                sIdx=uPairs(opt,1);
                dIdx=uPairs(opt,2);
                srcPosX(opt)=device.Probe{p}.SrcPosX(sIdx);
                srcPosY(opt)=device.Probe{p}.SrcPosY(sIdx);
                srcPosZ(opt)=device.Probe{p}.SrcPosZ(sIdx);
                detPosX(opt)=device.Probe{p}.DetPosX(dIdx);
                detPosY(opt)=device.Probe{p}.DetPosY(dIdx);
                detPosZ(opt)=device.Probe{p}.DetPosZ(dIdx);
                srcPos3D(opt,:)=device.Probe{p}.SrcPos3D(sIdx,:);
                detPos3D(opt,:)=device.Probe{p}.DetPos3D(dIdx,:);
            end
            
            device.Probe{p}.SrcPosX=srcPosX';
            device.Probe{p}.SrcPosY=srcPosY';
            device.Probe{p}.SrcPosZ=srcPosZ';
            device.Probe{p}.DetPosX=detPosX';
            device.Probe{p}.DetPosY=detPosY';
            device.Probe{p}.DetPosZ=detPosZ';
            
            device.Probe{p}.OptPosX=mean([device.Probe{p}.SrcPosX(:,1),device.Probe{p}.DetPosX(:,1)],2);
            device.Probe{p}.OptPosY=mean([device.Probe{p}.SrcPosY(:,1),device.Probe{p}.DetPosY(:,1)],2);
            device.Probe{p}.OptPosZ=mean([device.Probe{p}.SrcPosZ(:,1),device.Probe{p}.DetPosZ(:,1)],2);
            device.Probe{p}.NumOptodes=length(device.Probe{p}.OptPosX);

            device.Probe{p}.OptPos=table();
            device.Probe{p}.OptPos.x_2d=device.Probe{p}.OptPosX(:);
            device.Probe{p}.OptPos.y_2d=device.Probe{p}.OptPosY(:);
            device.Probe{p}.OptPos.z_2d=device.Probe{p}.OptPosZ(:);
            device.Probe{p}.DetPos3D=detPos3D;
            device.Probe{p}.SrcPos3D=srcPos3D;
            
            device.Probe{p}.OptPos3D=(srcPos3D+detPos3D)/2;
            device.Probe{p}.OptPos.x=device.Probe{p}.OptPos3D(:,1);
            device.Probe{p}.OptPos.y=device.Probe{p}.OptPos3D(:,2);
            device.Probe{p}.OptPos.z=device.Probe{p}.OptPos3D(:,3);
            
            device.Probe{p}.SD=sqrt(sum((srcPos3D-detPos3D).^2,2))'/10; % mm -> cm
            device.Probe{p}.IsShortSeparation=device.Probe{p}.SD<2;
            
            numCh=size(uPairs,1);
            
            device.Probe{p}.probeNum=probeInfo.SD.MeasList(curProbeIdx,3);
            device.Probe{p}.wvI=probeInfo.SD.MeasList(curProbeIdx,4);
            device.Probe{p}.ChannelNumbers=uPairIdx';
            device.Probe{p}.ChannelList= 1:numCh;
            device.Probe{p}.Wavelength=probeInfo.SD.Lambda(:)'; % unique list, indexed by wvI
            device.Info.NumberChannels=device.Info.NumberChannels+numCh;

            % Assemble the canonical per-channel optode table from the geometry
            % computed above so processFNIRS2 / pf2.Device can resolve this
            % probe (device resolution, MNI positions, SD distances) without a
            % .cfg. Mirrors the TableOpt that pf2_base.loadDeviceCfg emits.
            device.Probe{p}.TableOpt=pf2_base.buildOptodeTable(device.Probe{p});




            %numCh=length(unique(device.Probe{p}.ChannelNumbers));

            if(buildProbeLayout) % auto generate plot layour
                if(isfield(device.Probe{p},'OptPosX')&&isfield(device.Probe{p},'OptPosY'))
                    if(includeSSchannels)
                        device.Probe{p}.OptLayout2D_ss=pf2_base.fitProbe2D(device.Probe{p}.OptPosX,device.Probe{p}.OptPosY,device.Probe{p}.OptPosZ,false);
                    end
                        device.Probe{p}.OptLayout2D=pf2_base.fitProbe2D(device.Probe{p}.OptPosX(~device.Probe{p}.IsShortSeparation)...
                            ,device.Probe{p}.OptPosY(~device.Probe{p}.IsShortSeparation),...
                            device.Probe{p}.OptPosZ(~device.Probe{p}.IsShortSeparation),false);
                    
                else
                    warning('buildProbeLayout option selected, but not enough information to generate Optode locations');
                    device.Probe{p}.OptLayout2D=setUpFalse2D(device.Probe{p}.NumOptodes);  % generate false channels if not requested
                end
            else
                device.Probe{p}.OptLayout2D=setUpFalse2D(device.Probe{p}.NumOptodes);  % generate false channels if not requested
            end

            device.Probe{p}.OptPos.subplot_layout(:)=cell(size(device.Probe{p}.OptPos.z));
            device.Probe{p}.OptPos.subplot_layout(~device.Probe{p}.IsShortSeparation)=device.Probe{p}.OptLayout2D(:);
            if(includeSSchannels)
                device.Probe{p}.OptPos.subplot_layout_ss=device.Probe{p}.OptLayout2D_ss(:);
            else
               device.Probe{p}.OptPos.subplot_layout_ss= device.Probe{p}.OptPos.subplot_layout;
            end
        
        end
        
        
        
    end
    
    if(strcmp(files{i,2},'info'))
        filenameParts=strsplit(filename,'.');
        fileroot=filenameParts{1};
        fNIR.info.probeInfo=pf2_base.external.INI('File',filename);
        fNIR.info.probeInfo.read();
        pInfo=fNIR.info.probeInfo;
        
        if(isprop(pInfo,'Markers')&&isfield(pInfo.Markers,'Events'))
            NIRX_mrk=strsplit(pInfo.Markers.Events,'\n');
            numL=0;
            for l=1:length(NIRX_mrk)
                splitLine=strsplit(NIRX_mrk{l},'\t');
                if(length(splitLine)>1)
                    numL=numL+1;
                    mrkRows(numL,:)=str2double(splitLine); %#ok<AGROW>
                end
            end
            if(numL>0)
                fNIR.markers=pf2_base.normalizeMarkers(mrkRows);
            end
        end
        
        if(isprop(pInfo,'ImagingParameters')&&isfield(pInfo.ImagingParameters,'SamplingRate'))
            fNIR.fs=pInfo.ImagingParameters.SamplingRate;
            fNIR.info.SamplingRate=fNIR.fs;
        end
        
        if(isprop(pInfo,'ImagingParameters')&&isfield(pInfo.ImagingParameters,'Wavelengths'))
            s=pInfo.ImagingParameters.Wavelengths;
            s(s==''''|s=='"')=[];
            s=strsplit(s,'\t');
            fNIR.info.curWv=str2double(s);
        end
        
        if(isprop(pInfo,'DataStructure')&&isfield(pInfo.DataStructure,'S_D_Key'))
            s=pInfo.DataStructure.S_D_Key;
            s(s==''''|s=='"')=[];
            sdkeyLines=strsplit(s,',');
            for l=1:length(sdkeyLines) % Source, Detector, Channel
                fNIR.info.sd_key(l,:)=str2double(strsplit(sdkeyLines{l},{'"','-',':'}));
            end
        end
        
        if(isprop(pInfo,'DataStructure')&&isfield(pInfo.DataStructure,'S_D_Mask'))
            s=pInfo.DataStructure.S_D_Mask;
            s(s==''''|s=='"')=[];
            sdmaskLines=strsplit(s,'\n');
            numL=0;
            for l=1:length(sdmaskLines)
                splitLine=strsplit(sdmaskLines{l},'\t');
                if(length(splitLine)>1)
                    numL=numL+1;
                    fNIR.info.sd_mask(numL,:)=str2double(splitLine);
                end
            end
        end
        
        if(isprop(pInfo,'ChannelsDistance')&&isfield(pInfo.ChannelsDistance,'ChanDis'))
            s=pInfo.ChannelsDistance.ChanDis;
            s(s==''''|s=='"')=[];
            splitLine=strsplit(s,'\t');
            fNIR.info.ChanDis=str2double(splitLine)/10; %convert to cm
        end
        
        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Subject'))
            fNIR.info.SubjectID=pInfo.GeneralInfo.Subject;
        end
        
        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'FileName'))
            fNIR.info.Filename=pInfo.GeneralInfo.FileName;
        end
        
        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Date'))
            fNIR.info.Date=stripQuotes(pInfo.GeneralInfo.Date);
        end

        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Time'))
            fNIR.info.Time=stripQuotes(pInfo.GeneralInfo.Time);
        end

        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Device'))
            fNIR.info.Device=stripQuotes(pInfo.GeneralInfo.Device);
        end

        if(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Device_ID'))
            fNIR.info.DeviceID=stripQuotes(pInfo.GeneralInfo.Device_ID);
        end
    end
    
    if(strcmp(files{i,2},'j_info'))

        pInfo = jsondecode(fileread(filename));
        
        if(isfield(pInfo,'montage_path'))
            fNIR.info.montage_path=pInfo.montage_path;
        end
    end
    
    if(strcmp(files{i,2},'j_description'))

        pInfo = jsondecode(fileread(filename));
        
        if(isfield(pInfo,'subject'))
            fNIR.info.SubjectID=pInfo.subject;
        end
        
        
        if(isfield(pInfo,'age')&&~isempty(pInfo.age))
            fNIR.info.Age=pInfo.age;
        else
            fNIR.info.Age=[];
        end
        
        if(isfield(pInfo,'gender'))
            fNIR.info.Sex='';
        end
        
        if(isfield(pInfo,'contact_info'))
            fNIR.info.contact_info='';
        end
        
        if(isfield(pInfo,'experiment'))
            fNIR.info.Session='';
        end
        
        if(isfield(pInfo,'remarks'))
            fNIR.info.remarks='';
        end
    end
end


if(isempty(fNIR.raw))
    numWv=length(wvCell);

    if(numWv>0)
       sampleNum=size(wvCell{1},1);
       numCh=size(wvCell{1},2);
    else
       error('pf2:importNIRX:noWavelengthFiles', 'Unable to find any .wv* files');
    end

    fNIR.raw=nan(sampleNum,numCh*numWv+1);


    for w=1:numWv
        wvRaw=wvCell{w};
        fNIR.raw(:,(1:numCh)*numWv-numWv+w+1)=wvRaw;

    end

    if(isfield(fNIR,'fs'))
        fNIR.raw(:,1)=[1:sampleNum]'./fNIR.fs;
    else
       error('pf2:importNIRX:missingSamplingRate', 'Sampling Frequency is missing');
    end
    
    
    if(isfield(fNIR.info,'sd_key')&&isfield(fNIR.info,'sd_mask'))
        for x=1:size(fNIR.info.sd_mask,1)
           for y=1:size(fNIR.info.sd_mask,2)
               if(fNIR.info.sd_mask(x,y)==1)
                   sdkey_chIdx=fNIR.info.sd_key(:,1)==x&fNIR.info.sd_key(:,2)==y;
                   fNIR.fchMask(fNIR.info.sd_key(sdkey_chIdx,3))=1;
               end
           end
        end
    end
    
    numRawChannels=size(data,1)-1;

    switch(numRawChannels)
        case 49
            fNIR.info.probename='NIRX_Sport_8x8_frontal';
        otherwise
            warning('Unidentified Probe\n');
            fNIR.info.probename='Unidentified .nirx file';
    end
else
    fNIR.info.probename='generated NIRX file';
end

fNIR.fchMask=ones(1,numCh);

% Recording start from the .hdr Date/Time (local wall-clock time, no zone)
if(isfield(fNIR,'info')&&isfield(fNIR.info,'Date'))
    hdrTime='';
    if(isfield(fNIR.info,'Time'))
        hdrTime=fNIR.info.Time;
    end
    t0=parseHdrDateTime(fNIR.info.Date,hdrTime);
    if(~isempty(t0))
        fNIR.t0=t0;
        fNIR.info.StartDateTime=t0;
    else
        warning('pf2:importNIRX:unparsedStartTime', ...
            'Could not parse .hdr Date/Time ''%s %s''; recording start time not set.', ...
            fNIR.info.Date,hdrTime);
    end
end

% Device model and sampling rate from the .hdr
if(isstruct(device)&&isfield(device,'Info'))
    if(isfield(fNIR,'info')&&isfield(fNIR.info,'Device')&&~isempty(fNIR.info.Device))
        device.Info.Name=fNIR.info.Device;
    elseif(isfield(fNIR,'info')&&isfield(fNIR.info,'DeviceID')&&~isempty(fNIR.info.DeviceID))
        model=modelFromDeviceID(fNIR.info.DeviceID);
        if(~isempty(model))
            device.Info.Name=model;
        end
    end
    if(isfield(fNIR,'fs')&&~isempty(fNIR.fs))
        device.Info.DefaultSamplingRate=fNIR.fs;
        device.Info.MaxSamplingRate=fNIR.fs;
    end
end

fNIR.probeinfo=device;

% Attach Device object for self-describing data
fNIR.device = pf2.Device.fromProbeInfo(device);

if(~channelCheck)
    ch_mask_file=sprintf('%s_CH.mat',fileroot);

    try
        fmask=load(ch_mask_file,'fmask');
        fmask=fmask.fmask;
        fprintf('%i Channels marked bad\n',sum(fmask<1));
    catch
        fprintf('No channel rejection present\n');
        fmask=[];
    end
else
   fmask=[]; 
end

if(channelCheck && pf2_base.allowChannelCheckGUI())
    if channelCheckVersion == 2
        app = pf2.qc.ChannelCheck(fNIR, 'CalledFromImport', true, 'SkipConfirmation', true);
        if isvalid(app), fNIR = app.OutputData; delete(app); end
    else
        fNIR=probeCheckGUI(fNIR,sprintf('%s.nirs',fileroot),forceChannelCheck);
    end
elseif(channelCheck)
    % Requested but the GUI is unavailable/suppressed (headless, under test,
    % or disabled): honor a saved sidecar mask if present, otherwise the
    % all-good default already in fNIR.fchMask.
    fNIR=pf2_base.loadExistingMaskOrCheck(fNIR,sprintf('%s.nirs',fileroot),channelCheckVersion);
else
   if(~isempty(fmask))
       fNIR.fchMask=fmask;
   end
end



if(isfield(fNIR,'probeinfo'))
   global setF
   device.cfg.add('Info',device.Info);
   for i=1:length(device.Probe)
       device.cfg.add(sprintf('Probe%i',i),device.Probe{i});
   end

   setF.device=device;
   
end

% cd restored automatically by cdCleanup
end



function s=stripQuotes(s)
% Remove the surrounding quotes NIRx writes around .hdr string values
if(isnumeric(s))
    s=num2str(s);
end
s=strtrim(char(string(s)));
s(s=='"'|s=='''')=[];
s=strtrim(s);
end


function t0=parseHdrDateTime(dateStr,timeStr)
% Parse the .hdr GeneralInfo Date and Time into a datetime (no time zone).
% NIRStar and Aurora write several date layouts depending on version/locale;
% some write the full timestamp in Date (yyyy-MM-dd HH:mm:ss.SSSSSS).
t0=[];
dateTimeFmts={'yyyy-MM-dd HH:mm:ss.SSSSSS','yyyy-MM-dd HH:mm:ss.SSS','yyyy-MM-dd HH:mm:ss'};
for f=1:numel(dateTimeFmts)
    try
        t0=datetime(dateStr,'InputFormat',dateTimeFmts{f},'Locale','en_US');
        t0.Format='yyyy-MM-dd HH:mm:ss.SSS';
        return;
    catch
    end
end
dateFmts={'eee, MMM dd, yyyy','eee, dd MMM yyyy','eee dd MMM yyyy','eee, MMMM dd, yyyy', ...
    'yyyy-MM-dd','dd.MM.yyyy','MM/dd/yyyy','dd MMM yyyy'};
timeFmts={'HH:mm:ss.SSS','HH:mm:ss','hh:mm:ss.SSS a','hh:mm:ss a','HH:mm'};
if(isempty(timeStr))
    timeFmts={''};
end
str=strtrim(sprintf('%s %s',dateStr,timeStr));
for d=1:numel(dateFmts)
    for t=1:numel(timeFmts)
        fmt=strtrim(sprintf('%s %s',dateFmts{d},timeFmts{t}));
        try
            t0=datetime(str,'InputFormat',fmt,'Locale','en_US');
            t0.Format='yyyy-MM-dd HH:mm:ss.SSS';
            return;
        catch
        end
    end
end
t0=[];
end


function model=modelFromDeviceID(deviceID)
% Map a .hdr Device ID to the NIRx device model; empty when unrecognized
model='';
patterns={'nirsport\s*-?\s*2|^nsp2','NIRSport2'; 'nirscout\s*-?\s*x','NIRScoutX'; ...
    'nirscout','NIRScout'; 'nirsport|^nsp','NIRSport'};
for k=1:size(patterns,1)
    if(~isempty(regexpi(deviceID,patterns{k,1},'once')))
        model=patterns{k,2};
        return;
    end
end
end


function [src2D,det2D]=layout2D(srcPos,detPos)
% 2D optode layout in the units of the 3D positions, as a top view (anterior
% up, the subject's right on the right). Positions that are already planar
% (a NIRStar 2D montage) are used as they are. Positions on a surface around
% the origin (head coordinates, z superior) are flattened with an azimuthal
% equidistant projection about the vertex, which keeps distances from the
% vertex. Other 3D positions are projected onto their best-fit plane, with
% axes aligned to x and y.
P=[srcPos;detPos];
nSrc=size(srcPos,1);
if(size(P,2)<3)
    P(:,3)=0;
end
rng=max(P,[],1)-min(P,[],1);
r=sqrt(sum(P.^2,2));
if(rng(3)<=1e-6*max([rng(1:2),1]))
    XY=P(:,1:2);
elseif(all(r>0)&&std(r)/mean(r)<0.2)
    d=P./r;
    theta=acos(max(-1,min(1,d(:,3))));
    phi=atan2(d(:,2),d(:,1));
    XY=mean(r)*theta.*[cos(phi),sin(phi)];
else
    c=mean(P,1);
    [V,D]=eig(cov(P-c));
    [~,iMin]=min(diag(D));
    n=V(:,iMin)';
    e1=[1 0 0]-dot([1 0 0],n)*n;
    if(norm(e1)<0.3)
        e1=[0 1 0]-dot([0 1 0],n)*n;
    end
    e1=e1/norm(e1);
    e2=[0 1 0]-dot([0 1 0],n)*n-dot([0 1 0],e1)*e1;
    if(norm(e2)<0.3)
        e2=[0 0 1]-dot([0 0 1],n)*n-dot([0 0 1],e1)*e1;
    end
    e2=e2/norm(e2);
    XY=[(P-c)*e1',(P-c)*e2'];
end
src2D=XY(1:nSrc,:);
det2D=XY(nSrc+1:end,:);
end


function opt_2d_coords=setUpFalse2D(numCh)

for i=1:numCh
    x1=i-1;
    x2=1;
    y1=0;
    y2=0.9;
    x2=x2/numCh;
    x1=x1/numCh;
    
    opt_2d_coords{i}=[x1,y1,x2,y2];
end
end



