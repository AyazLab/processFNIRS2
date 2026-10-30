function [fNIR] = importNIR(nir_filename, mrk_filename, channelCheck, varargin)
% IMPORTNIR Import fNIRS data from fNIR Devices/Biopac .nir files
%
% Imports raw fNIRS data from COBI Studio software (.nir files) used with
% fNIR Devices systems (fNIR 1000, fNIR 2000, etc.) and Biopac fNIRS devices.
% Automatically loads associated marker files and optionally displays a
% channel quality check GUI.
%
% Syntax:
%   fNIR = pf2.import.importNIR()                          % GUI file selection
%   fNIR = pf2.import.importNIR(nir_filename)              % Load specific file
%   fNIR = pf2.import.importNIR(nir_filename, mrk_filename)
%   fNIR = pf2.import.importNIR(nir_filename, mrk_filename, channelCheck)
%   fNIR = pf2.import.importNIR(nir_filename, true)        % Auto-find markers
%   fNIR = pf2.import.importNIR(nir_filename, false, false) % Skip marker & check
%
% Inputs:
%   nir_filename  - Path to .nir data file (optional)
%                   If empty or not provided, opens file selection dialog.
%   mrk_filename  - Marker file specification (optional):
%                   - String: Path to specific .mrk file
%                   - Cell array: Multiple marker files to merge
%                   - true: Auto-search for .mrk files (default)
%                   - false: Skip marker loading
%   channelCheck  - Display channel quality GUI (default: true)
%                   Shows raw light intensity for visual quality assessment.
%                   Cached results are reused unless forced.
%
% Outputs:
%   fNIR          - fNIRS data structure containing:
%                   .raw [T x C] - Raw light intensity data
%                   .time [T x 1] - Time vector in seconds
%                   .fs - Sampling frequency in Hz
%                   .fchMask [1 x C] - Channel validity mask (1=good, 0=bad)
%                   .markers [M x 4] - Event markers (time, code, duration, amplitude)
%                   .info - Metadata structure:
%                       .header - File header information
%                       .mrkheaders - Marker file headers
%                       .filename - Source file path
%                       .probename - Device configuration name
%
% Marker Auto-Search:
%   When mrk_filename is true or omitted, searches for:
%   - {fileroot}.mrk
%   - {fileroot}_C.mrk
%   - {fileroot}_biopac.mrk
%   - {fileroot}_*.mrk (any matching pattern)
%
% Notes:
%   - Time column is assumed to be first column in data
%   - Baseline data is included as continuous recording (t < 0)
%   - Channel check results are cached in {filename}_pf2mask.mat
%   - Requires device configuration to be loaded (pf2.settings.selectDevice)
%   - Markers are read from <name>.mrk, <name>_C.mrk, <name>_Mark1.mrk and
%     <name>_Mark2.mrk when present. In automatic marker files the columns
%     are Time, Code, Duration, then any further columns (a fourth column is
%     Amplitude). COBI Studio writes a non-decreasing integer in the third
%     column, not an event length, so Duration from COBI files is not a
%     duration; pf2.export.asNIR writes real durations there. Manual marker
%     files (time stamps against the start code) get Duration 100, and
%     Amplitude is 1 unless the file has a fourth column.
%   - When markers come from more than one .mrk file, a MarkerSource column
%     holds the file each marker came from (1 = <name>.mrk, 2 = <name>_C.mrk,
%     3 = <name>_Mark1.mrk, 4 = <name>_Mark2.mrk).
%   - COBI Studio Modern files whose last column is the device sample counter
%     are timed from the counter (pf2_base.nirCounterTimebase): the counter
%     tick is fitted to the PC clock (33/32768 s by default on the 2000M,
%     1 ms on the 2000S and 3000C), each segment between counter resets is
%     anchored to its PC latency floor, and fs is 1/(tick x mean counts per
%     sample). Segment, gap and latency QC is in info.timebase. Other files
%     use the PC time column.
%   - t0 is the header Start Time as local wall-clock time with no time zone;
%     pass 'TimeZone' to pf2.export.asSNIRF to write absolute times.
%
% Example:
%   % Interactive file selection
%   data = pf2.import.importNIR();
%
%   % Load specific file with auto marker detection
%   data = pf2.import.importNIR('subject01.nir');
%
%   % Load without channel check GUI (batch processing)
%   data = pf2.import.importNIR('subject01.nir', true, false);
%
% See also: pf2.import.importSNIRF, pf2.import.importNIRX, pf2.export.asNIR
%
% Change Log:
%   4/30/2019 - Fixed incomplete baseline error
%   3/29/2019 - Cell array marker support, strsplit parsing
%   2/1/2019 - Output as fNIR struct, continuous baseline

pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

fNIR=[]; % placeholder initializations
data=[]; 
markers=[];
baseline=[];
fchMask=[];
autoLoadMrk=true;

forceChannelCheck=false; % if channelcheck is enabled manually, then honor, otherwise load only first time
channelCheckVersion=pf2_base.channelCheckVersion();
for vi_=1:2:numel(varargin)
    if ischar(varargin{vi_}) && strcmpi(varargin{vi_},'ChannelCheckVersion')
        channelCheckVersion=varargin{vi_+1};
    end
end

if nargin < 1 % No Arguments - Open fNIRS and mrk file
	[nir_filename, pathname] = uigetfile({'*.nir';'*.*'},'Open fNIRS nir_filename');
	nir_filename=[pathname nir_filename];
    
    if(isempty(nir_filename)||~isstr(nir_filename))
       return; 
    end
	
	[mrk_filename, pathnameM] = uigetfile({'*.mrk';'*.*'},'Open fNIRS mrk nir_filename',pathname);
	mrk_filename=[pathnameM mrk_filename];
    
    if(~isstr(mrk_filename)) %cancelled
        mrk_filename=[];
    end
    autoLoadMrk=false;
	channelCheck=true; %Plots raw channel light intensity and asks user to mark as either noisy, invalid, or clean
elseif nargin<2
    if(isempty(nir_filename))
        [nir_filename, pathname] = uigetfile({'*.nir';'*.*'},'Open fNIRS nir_filename');
        nir_filename=[pathname nir_filename];

        if(isempty(nir_filename)||~isstr(nir_filename))
           return; 
        end
    end
    
    channelCheck=true; %Plots raw channel light intensity and asks user to mark as either noisy, invalid, or clean
    mrk_filename=[];
    autoLoadMrk=true;
elseif nargin<3
    if(isempty(nir_filename))
        [nir_filename, pathname] = uigetfile({'*.nir';'*.*'},'Open fNIRS nir_filename');
        nir_filename=[pathname nir_filename];

        if(isempty(nir_filename)||~isstr(nir_filename))
           return; 
        end
    end
    
    if(islogical(mrk_filename))
        autoLoadMrk=mrk_filename; 
    else
       autoLoadMrk=false; 
    end
    channelCheck=true; %Plots raw channel light intensity and asks user to mark as either noisy, invalid, or clean
else
    if(isempty(nir_filename))
        [nir_filename, pathname] = uigetfile({'*.nir';'*.*'},'Open fNIRS nir_filename');
        nir_filename=[pathname nir_filename];

        if(isempty(nir_filename)||~isstr(nir_filename))
           return; 
        end
    end
    if(islogical(mrk_filename))
        autoLoadMrk=mrk_filename; 
    else
       autoLoadMrk=false; 
    end
    forceChannelCheck=true;
    % if channel Check is enabled, will force the GUI to load even if the
    % file already exists
end

if(isstring(nir_filename))
   nir_filename=char(nir_filename); 
end

if ~ischar(nir_filename)
	error('pf2:importNIR:badInput', 'Input must be a string representing a filename');
end

if(~isempty(nir_filename))
	fid = fopen(nir_filename);
end

if fid==-1
	error('pf2:importNIR:fileNotFound', 'Data nir_filename not found or permission denied');
end



header.fname=nir_filename;

fileroot=nir_filename(1:strfind(lower(nir_filename),'.nir')-1);
fileroot_modern=fileroot(1:strfind(lower(nir_filename),'_dev')-1);

if(contains(fileroot,'_Dev'))
    fileroot=fileroot_modern;
end


if(autoLoadMrk)
   mrk_filename=cell(4,1);
   mrk_filename{1}=sprintf('%s.mrk',fileroot);
   mrk_filename{2}=sprintf('%s_C.mrk',fileroot);
   mrk_filename{3}=sprintf('%s_Mark1.mrk',fileroot_modern);
   mrk_filename{4}=sprintf('%s_Mark2.mrk',fileroot_modern);
elseif(ischar(mrk_filename)||isstring(mrk_filename))
    mrk_filename={sprintf('%s',mrk_filename)};
end



%Default names for markers, manual markers, and log file


log_filename=sprintf('%s.log',fileroot);

log_info=importCOBIlog(log_filename);

hasDataSource=false;


lineF=fgetl(fid);
while(ischar(lineF))
    if(contains(lineF, 'Start Code:'))
        sC=strsplit(lineF,'\t');
        if(length(sC)>1&&~isempty(sC{2}))
            header.startCodeAlt=str2double(sC{2}); %Start code for start of .nir file
        end
        if(length(sC)>2&&~isempty(sC{3}))
            header.startCode=str2double(sC{3})/1000; %start code for start of experiment
            if((header.startCodeAlt-header.startCode)>1)
                %warning(sprintf('StartCode Diff %.2f\nMay affect manual marker integrity\n',(header.startCodeAlt-header.startCode)));
            end
        else
            header.startCode=header.startCodeAlt; %if second code is missing, just use first
        end
        
    elseif(~isempty(strfind(lineF, 'Freq Code:')))
        header.freqCode=sscanf(lineF,'Freq Code:\t%f\n',1);  %record frequency code
    elseif(~isempty(strfind(lineF, 'Current:')))
        header.current=sscanf(lineF,'Current:\t%f\n',1);  %record LED current used
    elseif(~isempty(strfind(lineF, 'Gains:')))
        header.gains=sscanf(lineF,'Gains:\t%f\n',1);  %record Detector Gain used
    elseif(~isempty(strfind(lineF, 'Other:')))
        header.other=sscanf(lineF,'Other:\t%s\n',1);  %record Detector Gain used
    elseif(~isempty(strfind(lineF,'Start Time:')))
       temp=strsplit(lineF,'\t');
       temp=temp{2};
       temp=strsplit(temp,' ');
       for i=1:length(temp)
          if(~isempty(strfind(temp,':')))
             header.Time=temp;

             temp2=lineF(13:end);
             try
                header.StartDateTime= datetime(temp2,'InputFormat','eee MMM dd HH:mm:ss.SSS yyyy'); % try to get timestamp with milliseconds
                fNIR.t0=header.StartDateTime;
             catch
                header.StartDateTime= datetime(temp2,'InputFormat','eee MMM dd HH:mm:ss yyyy'); % else use only regular seconds
                fNIR.t0=header.StartDateTime;
             end
          end
       end
    end

    if(~isempty(strfind(lineF,'SubjectID:')))
        lineF_parts=strsplit(lineF,'\t');

        id_idx=find(strcmp(lineF_parts,'SubjectID:'));
        header.SubjectId=lineF_parts{id_idx+1};
    end

    if(~isempty(strfind(lineF,'Data Source:')))
        lineF_parts=strsplit(lineF,'\t');

        id_idx=find(strcmp(lineF_parts,'Data Source:'));
        header.DataSource=lineF_parts{id_idx+1};
        hasDataSource=true;
    end
    
    lineF=fgetl(fid); %Get Next Line
    
    if(ischar(lineF)&&contains(lineF, 'Baseline Started'))
        countCheckFlag=true;
        lineF=fgetl(fid); %Get Next Line

        break;
    end
end


if(iscell(mrk_filename))
	
    % Normalize each marker file on its own (manual and automatic files have
    % different column counts), then merge. The index of the file a marker
    % came from is kept as MarkerSource only when more than one file
    % contributed markers.
    markerTbl=[];
    nSources=0;
    for i=1:length(mrk_filename)
		markerCell{i}=importMrk(mrk_filename{i},header.startCode);
        if(isfield(markerCell{i},'data')&&~isempty(markerCell{i}.data))
            fileTbl=pf2_base.normalizeMarkers(markerCell{i}.data);
            fileTbl(isnan(fileTbl.Time),:)=[];
            if(height(fileTbl)==0)
                continue;
            end
            fileTbl.MarkerSource=repmat(i,height(fileTbl),1);
            nSources=nSources+1;
            markerTbl=pf2_base.mergeMarkers(markerTbl,fileTbl);
        end
    end
    
    
    markers=markerCell{1};
    if(~isempty(markerTbl)) % Sort merged markers (.info sections are only preserved for first marker file)
        markerTbl=sortrows(markerTbl,'Time');
        if(nSources<2)
            markerTbl.MarkerSource=[];
        end
        markers.data=markerTbl;
    end
    
else
	markers=importMrk(mrk_filename,header.startCode);
end


spaceParsingMode=false;

if(~exist('strlen'))
    strlen_local=@strlength;
else
    strlen_local=@strlen;
end

while(ischar(lineF))
    
    if(countCheckFlag)
       countCheckFlag=false;
       strParts = strsplit(lineF,'\t');
       strParts = strParts(cellfun(strlen_local,strParts)>0);
       numVar=length(strParts);   
       
       if(numVar==1)
             numVar=length(strsplit(lineF,' '));   
            spaceParsingMode=true;
       end
       baseline=nan(1000,numVar);
       blLineCount=0;
    end
     if(contains(lineF, 'Baseline Started'))
         lineF=fgetl(fid); %Get Next Line
         continue;
     end
    
    if(contains(lineF, 'Baseline end'))
        baseline(isnan(baseline(:,1)),:)=[]; %trim NaN rows;
        baseline(baseline(:,1)<=0,:)=[]; %remove markerrows and zero rows
        lineF=fgetl(fid); %Get Next Line
       break; 
    end
    
    if(~countCheckFlag)
        blLineCount=blLineCount+1;
        [baseline(blLineCount,:), numVar]=sscanf(lineF,'%f',[1 numVar]);
    end
    lineF=fgetl(fid); %Get Next Line
end




if(lineF==-1)
   return;
else
    if(~spaceParsingMode)
        line1=str2double(strsplit(lineF,'\t'));
    else
        line1=str2double(strsplit(lineF,' '));
    end
end

while (ischar(lineF)&&length(line1)>1)&&(line1(1)<0) 
            % Keeps searching for first line with values if it can't find
            % it for some reason
    if(~spaceParsingMode)
        line1=str2double(strsplit(lineF,'\t'));
    else
        line1=str2double(strsplit(lineF,' '));
    end
    lineF=fgetl(fid); %Get Next Line
end

numVar=length(line1(~isnan(line1))); %Count Elements


data=nan(5e5,numVar); %overinitialize array



lineCount=1;
while(lineF~=-1)
    if(~spaceParsingMode)
        numTabs=sum(lineF(:)=='	');
        if(lineF(end)~='\t') %.nir files are terminared with \t\n, but not always true
            numTabs=numTabs+1;
        end
    else
        numTabs=sum(lineF(:)==' ');
        if(lineF(end)~=' ') %.nir files are terminared with \t\n, but not always true
            numTabs=numTabs+1;
        end
    end
    if(numTabs<numVar)
        data(lineCount,:)=zeros(1,numVar);
        count=numTabs;
    else
        [data(lineCount,:), count]=sscanf(lineF,'%f',[1 numVar]);
    end
    if(count==numVar)
        lineCount=lineCount+1;
    end
    lineF=fgetl(fid);
end
data(isnan(data(:,1)),:)=[]; %trim nan rows
data(data(:,1)<=0,:)=[]; %trim zero or negative rows

data=[[baseline,zeros(size(baseline,1),size(data,2)-size(baseline,2))];data];

fclose(fid);
clear fid line1 lineCount line







data(data(:,1)==0,:)=[];

justOnes=all(data==1);
justOnes_Baseline=all(baseline==1);

data=data(:,~justOnes); %Drop all columns that are only 1
baseline=baseline(:,~justOnes_Baseline); %Drop all columns that are only 1

%remove nan lines
allNaN = sum(isnan(data),2);
data(allNaN>0,:)=[];

% Check for sample count in last column and drop it (newer cobi)
lastCol=data(:,end);
% Device model from the header (COBI Studio Modern: 'Data Source: ..., Model 2000M Imager, ...')
model='';
if(hasDataSource)
    modelTok=regexp(header.DataSource,'Model\s+(\w+)','tokens','once');
    if(~isempty(modelTok))
        model=modelTok{1};
    end
end
% The counter is a rising integer column. Large values identify it on any
% device; on the models known to write it (2000M, 2000S, 3000C) a short
% recording whose counter is still small is recognised by its steady step.
% The 1200W counter is not used: those files stay on the PC time column.
firstSteps=diff(lastCol(1:min(100,end)));
isCounterModel=any(contains(model,{'2000M','2000S','3000C'}));
lastColIsSampleCount = all(firstSteps>0)&&(max(lastCol)>100000|| ...
    (isCounterModel&&all(lastCol==round(lastCol))&&median(firstSteps)>=10));

if(size(data,2)>(size(baseline,2))||lastColIsSampleCount) % Last column in newer cobi is sample count, but not included in baseline
     if(size(data,2)==size(baseline,2))
        baseline=baseline(:,1:end-1);
    end
    
    data=data(:,1:end-1);
end

timebase=[];
if(lastColIsSampleCount)
    % Time from the sample counter: tick fitted to the PC clock per segment,
    % each segment anchored to its latency floor (see pf2_base.nirCounterTimebase)
    [data(:,1),timebase]=pf2_base.nirCounterTimebase(data(:,1),lastCol,'Model',model);
end

fNIR.raw=data;
fNIR.time=data(:,1);
if(~isempty(timebase))
    fNIR.fs=timebase.fs;
else
    fNIR.fs=1./median(diff(fNIR.time));
end
fNIR.fchMask=fchMask;

if(isfield(markers,'data'))
	fNIR.markers=markers.data;
else
    fNIR.markers=[];
end
fNIR.markers = pf2_base.normalizeMarkers(fNIR.markers);

fNIR.info=[];

fNIR.info.header=header;

if(isfield(markers,'info'))
	fNIR.info.mrkheaders=markers.info;
end

fNIR.info.filename=nir_filename;
fNIR.info.baseline=baseline;
if(~isempty(timebase))
    fNIR.info.timebase=timebase;
end

if(~isempty(log_info)&&isfield(log_info,'SubjectID'))
    fNIR.info.SubjectID=log_info.SubjectID;
elseif(isfield(fNIR.info.header,'SubjectId'))
    fNIR.info.SubjectID=fNIR.info.header.SubjectId;
end
if(~isempty(log_info)&&isfield(log_info,'Experimenter'))
    fNIR.info.Experimenter=log_info.Experimenter;
end
    
if(~isempty(log_info)&&isfield(log_info,'ExperimentID'))
    fNIR.info.Session=log_info.ExperimentID;
end
    
if(~isempty(log_info)&&isfield(log_info,'Sex'))
    fNIR.info.Sex=log_info.Sex;
end

if(~isempty(log_info)&&isfield(log_info,'Age')&&~isnan(log_info.Age))
    fNIR.info.Age=log_info.Age;
end

if(~isempty(log_info))
    fNIR.info.log_info=log_info;
    % Fold the COBI Marker Dictionary into the canonical marker dictionary
    if(isstruct(log_info)&&isfield(log_info,'MarkerDict')&&~isempty(log_info.MarkerDict))
        try
            fNIR.info.markerDict=pf2_base.normalizeMarkerDict(log_info.MarkerDict);
        catch normErr
            % Leave markerDict unset if the COBI table can't be normalized,
            % but warn so the cause is visible (the column layout is parsed
            % from the .nir log header and may be unexpected).
            warning('pf2:importNIR:markerDictFailed', ...
                'Could not normalize COBI MarkerDict: %s', normErr.message);
        end
    end
end
    
%clear count;
%clear line;


numRawChannels=size(data,2)-1;

if(hasDataSource)
    [cfgName, modelToken, probeStyle] = resolveProbeFromDataSource(fNIR.info.header.DataSource);
    fprintf('Loading configuration for: Model %s %s\n', modelToken, probeStyle);

    if(~isempty(cfgName))
        fNIR.info.probename = cfgName;
        % Trim trailing columns based on the cfg's expected raw width.
        % Trailing columns may be unused detector slots reported by the imager.
        try
            dev = pf2.Device.load(cfgName);
            expectedCols = length(dev.wavelengths());
            if(size(fNIR.raw,2) >= expectedCols)
                fNIR.raw = fNIR.raw(:, 1:expectedCols);
            else
                warning('pf2:import:rawWidthMismatch', ...
                    'Probe %s expects %d raw columns; data has %d. Skipping trim.', ...
                    cfgName, expectedCols, size(fNIR.raw,2));
            end
        catch ME
            warning('pf2:import:probeLoadFailed', ...
                'Failed to load probe %s: %s', cfgName, ME.message);
        end
    else
        warning('pf2:import:unidentifiedProbe', ...
            'Unidentified probe (model "%s", style "%s")', modelToken, probeStyle);
        fNIR.info.probename = 'Unknown .nir file';
    end

else

    switch(numRawChannels)
        case 12
            fNIR.info.probename='fNIR_Devices_fNIR1000_Linear';
        case 48
            fNIR.info.probename='fNIR_Devices_fNIR1200_16ch';
        case 54
            fNIR.info.probename='fNIR_Devices_fNIR2000_18ch';
        otherwise
            warning('Unidentified Probe\n');
            fNIR.info.probename='Unknown .nir file';
    end

end

% Attach Device object for self-describing data
try
    fNIR.device = pf2.Device.load(fNIR);
catch
    % Unknown probe — skip device attachment
end


%clear linecount line times count;


if(~channelCheck)
    ch_mask_file=sprintf('%s_CH.mat',fileroot);

    try
        fmask=load(ch_mask_file,'fmask');
        fmask=fmask.fmask;
        nBad=sum(fmask<1);
        if(nBad>0)
            fprintf('%i channel(s) marked bad in saved rejection mask\n',nBad);
        end
    catch
        fprintf('\nNo channel rejection present\n');
        fmask=[];
    end
else
   fmask=[]; 
end

if(channelCheck)
    if(forceChannelCheck && pf2_base.allowChannelCheckGUI())
        if channelCheckVersion == 2
            app = pf2.qc.ChannelCheck(fNIR, 'CalledFromImport', true, 'SkipConfirmation', true);
            if isvalid(app), fNIR = app.OutputData; delete(app); end
        else
            fNIR=probeCheckGUI(fNIR,nir_filename,forceChannelCheck);
        end
    else
        % Non-forced, or the GUI cannot/should not be shown (headless, under
        % test, or disabled): load a saved mask if present; otherwise
        % loadExistingMaskOrCheck defaults all-good instead of blocking on the
        % channel-check window.
        fNIR=pf2_base.loadExistingMaskOrCheck(fNIR,nir_filename,channelCheckVersion);
    end
else
   if(~isempty(fmask))
       fNIR.fchMask=fmask;
   elseif isempty(fNIR.fchMask)
       % No saved mask and channel check skipped — default to all good.
       % Use device nChannels (not raw column count which includes wavelengths).
       if isfield(fNIR, 'device') && ~isempty(fNIR.device)
           fNIR.fchMask=ones(1,fNIR.device.nChannels);
       else
           % Fallback: guess from probename config
           try
               dev = pf2.Device.load(fNIR);
               fNIR.fchMask=ones(1,dev.nChannels);
           catch
               warning('pf2:import:unknownChannelCount', ...
                   'Cannot determine channel count for default fchMask. Set manually.');
           end
       end
   end
end

end

function loadExistingOrOpen()

end

function [cfgName, modelToken, probeStyle] = resolveProbeFromDataSource(dataSource)
% RESOLVEPROBEFROMDATASOURCE Map a COBI Studio "Data Source" string to a probe cfg.
%
% Parses comma-separated DataSource lines from COBI Studio. Tolerates
% formatting differences across COBI versions by:
%   - extracting model digits via regex anywhere in the string,
%   - scanning all parts for a known probe-style keyword (HD/HDS/Split/Linear/LD/SD),
%   - falling back to the second-to-last part (older versions) if no match.
%
% Examples handled:
%   'Device 1, Model 3000C Imager, Port 1, HD, 18 optodes'   (newer)
%   'Device 1, Model 2000S Imager, Port 1, HDS, 18 optodes'  (newer)
%   'Device 1, Model 1200W Imager, Port 1, HD, 16 optodes'   (newer)
%   'Device 1, Model 1000 Imager, Port 1, LD, 6 optodes'     (newer)
%   'Model 1000, HD'                                         (older / minimal)
%
% Returns:
%   cfgName    - Probe config name (without .cfg), or '' if unrecognized.
%   modelToken - Imager model token (e.g. '3000C', '2000S', '1200W', '1000').
%   probeStyle - Probe style token (e.g. 'HD', 'HDS', 'Split', 'Linear', 'LD').

    cfgName = '';
    modelToken = '';
    probeStyle = '';

    if(~ischar(dataSource) && ~isstring(dataSource))
        return;
    end
    parts = strtrim(strsplit(char(dataSource), ','));

    % Extract model token: "Model NNNN[X]" anywhere in the string.
    % "Imager" suffix is optional (older COBI versions may omit it).
    modelMatch = regexp(strjoin(parts, ', '), ...
        'Model\s+(\d+)([A-Za-z]*)', 'tokens', 'once');
    if(isempty(modelMatch))
        return;
    end
    modelDigits = modelMatch{1};
    modelToken = [modelDigits modelMatch{2}];

    % Find probe style by scanning parts for a known keyword.
    % This is more robust than position-based parsing across COBI versions.
    knownStyles = {'HDS','HD','Split','Linear','LD','SD'};
    for i = 1:numel(parts)
        token = regexp(parts{i}, '^[A-Za-z]+$', 'match', 'once');
        if(isempty(token)); continue; end
        idx = find(strcmpi(knownStyles, token), 1);
        if(~isempty(idx))
            probeStyle = knownStyles{idx};
            break;
        end
    end

    % Fallback: take second-to-last comma part (matches legacy parser).
    if(isempty(probeStyle) && numel(parts) >= 2)
        probeStyle = strtrim(parts{end-1});
    end

    cfgName = lookupProbeCfg(modelDigits, probeStyle);
end

function cfgName = lookupProbeCfg(modelDigits, probeStyle)
% LOOKUPPROBECFG Map (model digits, probe style) to a device cfg name.
%
% 3000-series imagers use the dedicated fNIR3000 cfg. Earlier-generation
% imagers (1000/1200/2000) share the probeStyle-based mapping that
% historically dispatched on style alone.

    cfgName = '';

    if(strcmp(modelDigits, '3000'))
        switch(probeStyle)
            case {'HD','HDS'}
                cfgName = 'fNIR_Devices_fNIR3000';
        end
        return;
    end

    switch(probeStyle)
        case {'HD','HDS'}      % 2x8 + 2 short-sep
            cfgName = 'fNIR_Devices_fNIR2000_18ch';
        case 'Split'           % 2x2
            cfgName = 'fNIR_Devices_fNIR1000_Split_2x2ch';
        case 'Linear'          % 1x4 linear
            cfgName = 'fNIR_Devices_fNIR1000_Linear';
        case 'LD'              % Square patch, detector at center, 4 corner sources
            cfgName = 'fNIR_Devices_fNIR1000_LD';
    end
end

function markers=importMrk(mrk_filename,startCode)
	if((ischar(mrk_filename)||isstring(mrk_filename))&&~isempty(mrk_filename))
		mrkid = fopen(mrk_filename);
	else
		mrkid=-1;
	end
	
	markers=[];

	if (mrkid==-1&&~isempty(mrk_filename))
		%disp('Marker nir_filename not found or permission denied: Loading without markers');
		return;
	elseif(mrkid==-1)
		%no file provided so just return
		return
	end
	
	
	lineF=fgetl(mrkid);
	if(lineF~=-1)
		[times, count]= sscanf(lineF,'%f\t%*d\t%*d\t%*s\t%*s %*s %*s %*s %*s\n', [1 inf]);
	else
		count=0;
		lineF='';
		fclose(mrkid);
		mrkid=-1;
	end
	
   if(count~=0)  % Then its a manual marker file
		markers=importManualMrkFile(mrkid,startCode,true);
	elseif contains(lower(lineF),'marker') % then its an automatic marker file
		markers=importMrkFile(mrkid);
	else
	   markers=[];
	end

	if(~isempty(markers))
		markers.info.fname=mrk_filename;
	end

end
function markers=importManualMrkFile(mrkid,startCode,useStrSplit)
    if(nargin<3)
        useStrSplit=true;
    end

	frewind(mrkid);
    
    markers.info.startcode=startCode; % time noting start of fNIRS file 
        % manual marker values are subtracted from this
	
    if(~useStrSplit) %faster but more error prone
	
        [times, count]= fscanf(mrkid,'%f\t%d\t%*d\t%*s\t%*s %*s %*s %*s %*s\n', [1 inf]);
        markers.data=nan(ceil(count/2),1);
        markers.data(:,3)=times(1:2:end)'; % marker time
        markers.data(:,2)=times(2:2:end)'; % marker code
        markers.data(:,1)=markers.data(:,3)-startCode; %adjusted marker time
        markers.data(:,3)=100; %We don't use marker time here, so just use 100 as the ID

    else
        linecount=0;
        lineF=fgetl(mrkid);
        markers.data=nan(1,3);
        while(lineF~=-1)
           temp=strsplit(lineF,'\t');
           if(length(temp)>=3)
               linecount=linecount+1;
                markers.data(linecount,3)=str2num(temp{1}); % marker time
                markers.data(linecount,2)=str2num(temp{2}); % marker code
                markers.data(linecount,1)=markers.data(linecount,3)-startCode; %adjusted marker time
                if(length(temp)>=5)
                    markers.info.markerDateTime{linecount}=temp{5};
                end
           else
               continue;
           end
           lineF=fgetl(mrkid);

        end
        
        markers.data(:,3)=100;
    end

   clear count;
   clear times;
   fclose(mrkid);
end


function markers=importMrkFile(mrkid)

    % Columns are read as time (s), marker code, duration (s), then any
    % further columns (e.g. amplitude) as written. COBI Studio writes a
    % non-decreasing integer in the third column, not a duration.
	frewind(mrkid);
	for i=1:5
		   lineF=fgetl(mrkid);
		   markers.info.headers{i,1}=lineF;
			  
		   if(contains(lineF,'Start Time:'))
			   temp=strsplit(lineF,'\t');
			   temp=temp{2};
			   temp=strsplit(temp,' ');
			   for i=1:length(temp)
				  if(contains(temp,':'))
					 markers.info.Time=temp;
				  end
			   end
		   end
	end

		
	linecount=0;
	lineF=fgetl(mrkid);
	markers.data=[];
	while(lineF~=-1)
	   linecount=linecount+1;
	   
       markerParts = strsplit(lineF,'\t');

       numTabs = length(markerParts);

       lineF=fgetl(mrkid);

       if(numTabs>0)
           if(contains(markerParts{1},':'))
               continue;
           end
       else
             continue;
       end

       mrkLine=nan([1,3]);
       
       for mrkI = 1:numTabs
            mrkLine(mrkI)=str2double(markerParts{mrkI});
       end

       markers.data=[markers.data;mrkLine];
    end

	fclose(mrkid);
end

    

function loginfo=importCOBIlog(log_filename)
    if(isstr(log_filename)&&~isempty(log_filename))
            logfid = fopen(log_filename);
        else
            logfid=-1;
    end
        
    loginfo=[];

    if (logfid==-1&&~isempty(log_filename))
        % Companion COBI log is optional; absence is the common case
        % (e.g. sample data), so proceed silently rather than warn.
        return;
    elseif(logfid==-1)
        %no file provided so just return
        return
    end
    
    linecount=1;
    
     lineF=fgetl(logfid);

    while(ischar(lineF))
       
       if(contains(lineF,'COBI log file'))
           loginfo.version=sscanf(lineF,'COBI log file %f');
       elseif(contains(lineF,'Experimenter:'))
           lineF=fgetl(logfid);
           if(lineF~=-1)
               loginfo.Experimenter=lineF;
           end
       elseif(contains(lineF,'SubjectID:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           if(lineF~=-1)
               loginfo.SubjectID=lineF;
           end
       elseif(contains(lineF,'ExperimentID:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           if(lineF~=-1)
               loginfo.ExperimentID=lineF;
           end
       elseif(contains(lineF,'Description:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           loginfo.Description='';
           while(lineF~=-1)
               if(isempty(loginfo.Description))
                   loginfo.Description=lineF;
               else
                   loginfo.Description=sprintf('%s\n%s',loginfo.Description,lineF);
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
      elseif(contains(lineF,'Data Sources:'))
           lineF=fgetl(logfid);
           loginfo.DataSources='';
           linecount=linecount+1;
           while(lineF~=-1)
               if(isempty(loginfo.DataSources))
                   loginfo.DataSources=lineF;
               else
                   loginfo.DataSources=sprintf('%s\n%s',loginfo.DataSources,lineF);
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
     elseif(contains(lineF,'Marker Sources:'))
           lineF=fgetl(logfid);
           loginfo.MarkerSources='';
           linecount=linecount+1;
           while(lineF~=-1)
               if(isempty(loginfo.MarkerSources))
                   loginfo.MarkerSources=lineF;
               else
                   loginfo.MarkerSources=sprintf('%s\n%s',loginfo.MarkerSources,lineF);
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
      elseif(contains(lineF,'Broadcasts:'))
           lineF=fgetl(logfid);
           loginfo.Broadcasts='';
           linecount=linecount+1;
           while(lineF~=-1)
               if(isempty(loginfo.Broadcasts))
                   loginfo.Broadcasts=lineF;
               else
                   loginfo.Broadcasts=sprintf('%s\n%s',loginfo.Broadcasts,lineF);
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
           
       elseif(contains(lineF,'Subject Info:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           if(lineF~=-1)
               loginfo.SubjectInfo=lineF;
           else
                loginfo.SubjectInfo='';
           end
           if(~isempty(loginfo.SubjectInfo))
               subInfoPart=strsplit(loginfo.SubjectInfo,'-');
               if(length(subInfoPart)>1)
                   if(contains(subInfoPart{2},'Male'))
                       loginfo.Sex='M';
                   elseif(contains(subInfoPart{2},'Female'))
                       loginfo.Sex='F';
                   else
                      loginfo.Sex=''; 
                   end
               else
                   loginfo.Sex='';
               end
               
               if(~isempty(subInfoPart))
                   loginfo.Age=str2double(subInfoPart{1});
               end
           
           end
       elseif(contains(lineF,'Comments:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           loginfo.Comments='';
           while(lineF~=-1)
               if(isempty(loginfo.Comments))
                   loginfo.Comments=lineF;
               else
                   loginfo.Comments=sprintf('%s\n%s',loginfo.Comments,lineF);
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
       elseif(contains(lineF,'Marker Dictionary:'))
           lineF=fgetl(logfid);
           linecount=linecount+1;
           if(lineF~=-1)
               tableHeaders=strsplit(lineF,'\t');
               lastItem=tableHeaders{end};
               if(lastItem(end)==':')
                   lastItem=lastItem(1:end-1);
                   tableHeaders{end}=lastItem;
               end
               
           else
              continue; 
           end
           lineF=fgetl(logfid);
           linecount=linecount+1;
           
           cellMarkerDict=cell(1,length(tableHeaders));
           numMrkDictItems=1;
           
           while(lineF~=-1)
               items=strsplit(lineF,'\t');
               if(~isempty(items)&&iscell(items))
                   cellMarkerDict(numMrkDictItems,1:length(items))=items;
                   numMrkDictItems=numMrkDictItems+1;
               end
               lineF=fgetl(logfid);
               linecount=linecount+1;
           end
           loginfo.MarkerDict=cell2table(cellMarkerDict(:,1:length(tableHeaders)),'VariableNames',tableHeaders);
           
       end
       lineF=fgetl(logfid);
       linecount=linecount+1;
       %disp(lineF)

    end
    fclose(logfid);
       

end

