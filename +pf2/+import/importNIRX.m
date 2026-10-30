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
%   fNIR = pf2.import.importNIRX(folderDIR, channelCheck, 'Model', 'NIRSport2')
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
%   - When <root>_probeInfo.mat is present its coordinates are used (the
%     vendor coordinate set NIRx's own SNIRF export writes): 3D positions in
%     mm, the vendor 2D layout, 10-10 optode labels, and the head model as
%     the coordinate system (ICBM152 is declared as MNI). Landmarks are read
%     from digpts.txt. Without it, the .nirs SD positions are used, which are
%     in a translated frame.
%   - t0 is the first frame time of the raw .roh stream (also read from
%     inside <root>.zip) when present, else the .hdr Date/Time
%   - 'Model' sets the device model name (e.g. 'NIRSport2') when the .hdr
%     only records a serial Device ID
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
modelOverride='';
for vi_=1:2:numel(varargin)
    if ischar(varargin{vi_}) && strcmpi(varargin{vi_},'ChannelCheckVersion')
        channelCheckVersion=varargin{vi_+1};
    elseif ischar(varargin{vi_}) && strcmpi(varargin{vi_},'Model')
        modelOverride=char(varargin{vi_+1});
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
nirsFile='';
nirsRoot='';

device=[];

for i=1:size(files,1)
    filename=files{i,1};
    if(strcmp(files{i,2},'wavelength'))
        
        strs=strsplit(filename,'.');
        wvNum=str2double(strs{end}(3));
        [wvCell{wvNum}] = dlmread(filename,' ');
    end
    
    if(strcmp(files{i,2},'nirs_file'))
        % Read after the loop, once the .hdr has been parsed
        filenameParts=strsplit(filename,'.');
        fileroot=filenameParts{1};
        nirsFile=filename;
        nirsRoot=fileroot;
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
            if(numL>0) % rows are time, code, frame; the frame is not a duration
                fNIR.markers=pf2_base.normalizeMarkers(mrkRows(:,1:2));
            end
        end
        
        if(isprop(pInfo,'ImagingParameters')&&isfield(pInfo.ImagingParameters,'SamplingRate'))
            fNIR.fs=pInfo.ImagingParameters.SamplingRate;
            fNIR.info.SamplingRate=fNIR.fs;
        elseif(isprop(pInfo,'GeneralInfo')&&isfield(pInfo.GeneralInfo,'Sampling_rate')) % Aurora
            fNIR.fs=pInfo.GeneralInfo.Sampling_rate;
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


% Recording data in .nirs form: the .nirs file when present, otherwise built
% from the NIRStar .wl* files, the .hdr channel key/mask and the .evt file
if(~isempty(nirsFile))
    probeInfo=load(nirsFile,'-mat');
elseif(~isempty(wvCell))
    nirsRoot=regexprep(strtok(files{find(strcmp(files(:,2),'wavelength'),1),1},'.'),'_config$','');
    probeInfo=nirsFromWavelengthFiles(wvCell,fNIR,nirsRoot);
    if((~isfield(fNIR,'markers')||isempty(fNIR.markers))&&isfile([nirsRoot '.evt']))
        evtMarkers=readEvt([nirsRoot '.evt'],1/median(diff(probeInfo.t)));
        if(~isempty(evtMarkers))
            fNIR.markers=evtMarkers;
        end
    end
    probeInfo=rmfield(probeInfo,'s');
else
    error('pf2:importNIRX:noData', ...
        'No .nirs file or .wl1/.wl2 wavelength files found next to ''%s''.', folderDIR);
end


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
    mrk=zeros(0,2);
    for mrkID=1:size(probeInfo.s,2)
        onsets=fNIR.time(probeInfo.s(:,mrkID)==1);
        mrk=[mrk;onsets(:),repmat(mrkID,numel(onsets),1)]; %#ok<AGROW>
    end
    fNIR.markers=pf2_base.normalizeMarkers(sortrows(mrk,1));
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
dataRoot=nirsRoot;

% Prefer the vendor coordinate set (<root>_probeInfo.mat, the source
% of NIRx's own SNIRF positions); the .nirs SD positions use a
% translated frame
vendorGeom=readVendorProbeInfo(sprintf('%s_probeInfo.mat',nirsRoot), ...
    size(probeInfo.SD.SrcPos,1),size(probeInfo.SD.DetPos,1));
if(isempty(vendorGeom)&&all(isnan(probeInfo.SD.SrcPos(:))))
    error('pf2:importNIRX:noGeometry', ...
        ['No optode positions: %s_probeInfo.mat is missing or does not match ' ...
         'the recording, and the wavelength files carry no geometry.'],nirsRoot);
end
if(~isempty(vendorGeom))
    probeInfo.SD.SrcPos=vendorGeom.src3D;
    probeInfo.SD.DetPos=vendorGeom.det3D;
    srcPos2D=vendorGeom.src2D;
    detPos2D=vendorGeom.det2D;
else
    [srcPos2D,detPos2D]=layout2D(probeInfo.SD.SrcPos,probeInfo.SD.DetPos);
end

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
    if(~isempty(vendorGeom)&&~isempty(vendorGeom.srcLabels))
        device.Probe{p}.SrcPos.Label=vendorGeom.srcLabels(:);
    end
    
    
    device.Probe{p}.DetPos=table();
    device.Probe{p}.DetPos.x_2d=device.Probe{p}.DetPosX(:);
    device.Probe{p}.DetPos.y_2d=device.Probe{p}.DetPosY(:);
    device.Probe{p}.DetPos.z_2d=device.Probe{p}.DetPosZ(:);
    device.Probe{p}.DetPos.x=probeInfo.SD.DetPos(:,1);
    device.Probe{p}.DetPos.y=probeInfo.SD.DetPos(:,2);
    device.Probe{p}.DetPos.z=probeInfo.SD.DetPos(:,3);
    if(~isempty(vendorGeom)&&~isempty(vendorGeom.detLabels))
        device.Probe{p}.DetPos.Label=vendorGeom.detLabels(:);
    end
    
  
    

   
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




fNIR.info.probename='generated NIRX file';
if(~isfield(fNIR,'markers'))
    fNIR.markers=pf2_base.normalizeMarkers([]); % empty marker table, as other importers return
end

fNIR.fchMask=ones(1,numCh);

if(~exist('dataRoot','var'))
    dataRoot=regexprep(fileroot,'_config$','');
end

% Recording start (local wall-clock time, no zone): the first frame of the
% raw .roh stream when present (the time NIRx's own SNIRF reports), else
% the .hdr Date/Time
t0=readRohStart(dataRoot);
if(~isempty(t0))
    fNIR.t0=t0;
    fNIR.info.StartDateTime=t0;
elseif(isfield(fNIR,'info')&&isfield(fNIR.info,'Date'))
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

% Device model (Model option, else the .hdr) and sampling rate from the .hdr
landmarks=[];
if(isstruct(device)&&isfield(device,'Info'))
    if(~isempty(modelOverride))
        device.Info.Name=modelOverride;
    elseif(isfield(fNIR,'info')&&isfield(fNIR.info,'Device')&&~isempty(fNIR.info.Device))
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

    % Coordinate system and landmarks of the vendor coordinate set
    if(exist('vendorGeom','var')&&~isempty(vendorGeom))
        if(~isempty(vendorGeom.headmodel))
            device.Info.CoordinateSystem='MNI';
            device.Info.CoordinateSystemDescription=sprintf( ...
                'NIRx %s head model coordinates (from _probeInfo.mat)',vendorGeom.headmodel);
        else
            device.Info.CoordinateSystem='Other';
            device.Info.CoordinateSystemDescription='NIRx probe coordinates (from _probeInfo.mat); head model not recorded';
        end
        [lmPos,lmLabels]=readDigpts(fullfile(pwd,'digpts.txt'));
        if(~isempty(lmPos))
            for p=1:numel(device.Probe)
                device.Probe{p}.landmarkPos3D=lmPos;
                device.Probe{p}.landmarkLabels=lmLabels;
            end
            landmarks=table(lmLabels(:),lmPos(:,1),lmPos(:,2),lmPos(:,3), ...
                'VariableNames',{'Label','X','Y','Z'});
            isFid=ismember(lower(lmLabels(:)),lower({'Nz','Iz','LPA','RPA'}));
            landmarks.Type=categorical(repmat("electrode",numel(lmLabels),1));
            landmarks.Type(isFid)=categorical("fiducial");
        end
    end
end

fNIR.probeinfo=device;

% Attach Device object for self-describing data
if(isempty(landmarks))
    fNIR.device = pf2.Device.fromProbeInfo(device);
else
    fNIR.device = pf2.Device.fromProbeInfo(device,[],'Landmarks',landmarks);
end

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



function nirs=nirsFromWavelengthFiles(wvCell,fNIR,root)
% .nirs-form data from NIRStar wavelength files. Each .wl<k> file holds one
% column per S-D-Key entry (every source-detector pair); S-D-Mask marks the
% measured channels. Positions are left NaN for <root>_probeInfo.mat.
if(~isfield(fNIR,'fs')||isempty(fNIR.fs))
    error('pf2:importNIRX:missingSamplingRate','Sampling rate is missing from the .hdr of %s.',root);
end
if(~isfield(fNIR,'info')||~isfield(fNIR.info,'sd_key')||~isfield(fNIR.info,'sd_mask'))
    error('pf2:importNIRX:missingChannelKey','S-D-Key/S-D-Mask are missing from the .hdr of %s.',root);
end
wvCell=wvCell(~cellfun(@isempty,wvCell));
numWv=numel(wvCell);
key=fNIR.info.sd_key;
mask=fNIR.info.sd_mask;
valid=false(size(key,1),1);
for k=1:size(key,1)
    valid(k)=key(k,1)<=size(mask,1)&&key(k,2)<=size(mask,2)&&mask(key(k,1),key(k,2))==1;
end
key=sortrows(key(valid,:),3);
nCh=size(key,1);
nSamples=size(wvCell{1},1);
d=zeros(nSamples,nCh*numWv);
for w=1:numWv
    if(size(wvCell{w},1)~=nSamples||size(wvCell{w},2)<max(key(:,3)))
        error('pf2:importNIRX:wavelengthFileSize', ...
            'Wavelength file %d of %s does not match the .hdr channel key.',w,root);
    end
    d(:,(w-1)*nCh+(1:nCh))=wvCell{w}(:,key(:,3));
end
lambda=[];
if(isfield(fNIR.info,'curWv'))
    lambda=fNIR.info.curWv(~isnan(fNIR.info.curWv));
end
if(numel(lambda)~=numWv)
    error('pf2:importNIRX:wavelengthCount', ...
        'The .hdr lists %d wavelengths but %d .wl files were found for %s.',numel(lambda),numWv,root);
end
nirs.t=(0:nSamples-1)'/fNIR.fs;
nirs.d=d;
nirs.s=[];
nirs.aux=[];
nirs.SD.Lambda=lambda(:)';
nirs.SD.SpatialUnit='mm';
nirs.SD.SrcPos=nan(max(key(:,1)),3); % optodes up to the highest one measured
nirs.SD.DetPos=nan(max(key(:,2)),3);
nirs.SD.MeasList=[repmat(key(:,1:2),numWv,1),ones(nCh*numWv,1),kron((1:numWv)',ones(nCh,1))];
end


function markers=readEvt(fname,fs)
% Markers from a NIRStar .evt file: each row is a frame index followed by
% the trigger-input bits, first input as the least significant bit. Onsets
% are frame/fs, as MNE-NIRS reads them.
markers=[];
frames=[];
codes=[];
lines=splitlines(fileread(fname));
for k=1:numel(lines)
    v=sscanf(lines{k},'%d')';
    if(numel(v)<2)
        continue;
    end
    frames(end+1,1)=v(1); %#ok<AGROW>
    codes(end+1,1)=sum(v(2:end).*2.^(0:numel(v)-2)); %#ok<AGROW>
end
if(~isempty(frames))
    markers=pf2_base.normalizeMarkers([frames/fs,codes]);
end
end


function geom=readVendorProbeInfo(fname,nSrc,nDet)
% Vendor probe geometry from a NIRx <root>_probeInfo.mat: 3D positions
% (coords_s3/coords_d3, cm, returned in mm), the vendor 2D layout
% (coords_s2/coords_d2, scaled by 10 as NIRx does in its SNIRF export),
% 10-10 optode labels and the head model name. Rows map to optode indices,
% so the file may list more optodes than the recording uses. Empty when the
% file is missing or lists fewer optodes than the recording.
geom=[];
if(~isfile(fname))
    return;
end
try
    P=load(fname,'probeInfo');
    probes=P.probeInfo.probes;
    if(size(probes.coords_s3,1)<nSrc||size(probes.coords_d3,1)<nDet)
        warning('pf2:importNIRX:probeInfoMismatch', ...
            '%s lists %d sources/%d detectors but the recording uses %d/%d; it is not used.', ...
            fname,size(probes.coords_s3,1),size(probes.coords_d3,1),nSrc,nDet);
        return;
    end
    geom.src3D=probes.coords_s3(1:nSrc,:)*10;
    geom.det3D=probes.coords_d3(1:nDet,:)*10;
    if(isfield(probes,'coords_s2')&&size(probes.coords_s2,1)>=nSrc&&isfield(probes,'coords_d2')&&size(probes.coords_d2,1)>=nDet)
        geom.src2D=probes.coords_s2(1:nSrc,:)*10;
        geom.det2D=probes.coords_d2(1:nDet,:)*10;
    else
        [geom.src2D,geom.det2D]=layout2D(geom.src3D,geom.det3D);
    end
    geom.srcLabels={};
    geom.detLabels={};
    if(isfield(probes,'labels_s')&&numel(probes.labels_s)>=nSrc&&isfield(probes,'labels_d')&&numel(probes.labels_d)>=nDet)
        geom.srcLabels=cellstr(probes.labels_s(1:nSrc));
        geom.detLabels=cellstr(probes.labels_d(1:nDet));
        geom.srcLabels=geom.srcLabels(:);
        geom.detLabels=geom.detLabels(:);
    end
    geom.headmodel='';
    if(isfield(P.probeInfo,'headmodel')&&~isempty(P.probeInfo.headmodel))
        geom.headmodel=char(P.probeInfo.headmodel);
    end
catch e
    warning('pf2:importNIRX:probeInfoUnreadable','Could not read %s: %s',fname,e.message);
    geom=[];
end
end


function [pos,labels]=readDigpts(fname)
% Landmarks from a NIRx digpts.txt ("name: x y z" in mm). Optode rows
% (s1.., d1..) are skipped; nz/iz/al/ar/cz become Nz/Iz/LPA/RPA/Cz.
pos=zeros(0,3);
labels={};
if(~isfile(fname))
    return;
end
names={'nz','Nz';'iz','Iz';'al','LPA';'ar','RPA';'cz','Cz'};
lines=splitlines(fileread(fname));
for k=1:numel(lines)
    tok=regexp(lines{k},'^\s*([^:\s]+)\s*:\s*(\S+)\s+(\S+)\s+(\S+)','tokens','once');
    if(isempty(tok)||~isempty(regexp(tok{1},'^[sd]\d+$','once')))
        continue;
    end
    xyz=str2double(tok(2:4));
    if(any(isnan(xyz)))
        continue;
    end
    lbl=tok{1};
    m=strcmpi(names(:,1),lbl);
    if(any(m))
        lbl=names{m,2};
    end
    pos(end+1,:)=xyz; %#ok<AGROW>
    labels{end+1,1}=lbl; %#ok<AGROW>
end
% Fiducials first in the order NIRx's SNIRF uses, then any other points
order={'Nz','Iz','LPA','RPA','Cz'};
[isStd,rank]=ismember(labels,order);
rank(~isStd)=numel(order)+find(~isStd);
[~,idx]=sort(rank);
pos=pos(idx,:);
labels=labels(idx);
end


function t0=readRohStart(root)
% Timestamp of the first frame in the NIRx raw stream (<root>.roh, or the
% .roh inside <root>.zip): each line starts "yyyy-MM-ddTHH:mm:ss.ffffff;".
% Empty when no .roh is found or its first line does not parse.
t0=[];
line='';
try
    if(isfile([root '.roh']))
        fid=fopen([root '.roh'],'r');
        line=fgetl(fid);
        fclose(fid);
    elseif(isfile([root '.zip']))
        zf=java.util.zip.ZipFile(java.io.File(fullfile(pwd,[root '.zip'])));
        zipCleanup=onCleanup(@() zf.close());
        entries=zf.entries();
        while(entries.hasMoreElements())
            entry=entries.nextElement();
            if(endsWith(lower(char(entry.getName())),'.roh'))
                reader=java.io.BufferedReader(java.io.InputStreamReader(zf.getInputStream(entry)));
                line=char(reader.readLine());
                reader.close();
                break;
            end
        end
    end
catch
    line='';
end
if(~ischar(line)||isempty(line))
    return;
end
stamp=strtok(line,';');
fmts={'yyyy-MM-dd''T''HH:mm:ss.SSSSSS','yyyy-MM-dd''T''HH:mm:ss.SSS','yyyy-MM-dd''T''HH:mm:ss'};
for f=1:numel(fmts)
    try
        t0=datetime(stamp,'InputFormat',fmts{f});
        t0.Format='yyyy-MM-dd HH:mm:ss.SSS';
        return;
    catch
    end
end
t0=[];
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



