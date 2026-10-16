function [fNIR] = importHitachiMES(file,pathname,channelCheck,varargin)
% IMPORTHITACHIMES Import fNIRS data from Hitachi ETG-4000 MES files
%
% Reads fNIRS data from Hitachi ETG-4000 optical topography systems, which
% export data in a proprietary CSV-based MES format. The MES file contains
% header metadata, wavelength information, marker events, and raw intensity
% data for all channels. Automatically detects probe configuration based on
% channel count (3x5 or 3x11 probe arrays).
%
% Reference:
%   Internal pf2 implementation for Hitachi ETG-4000 format.
%   Hitachi Medical Corporation. ETG-4000 Optical Topography System.
%
% Syntax:
%   fNIR = pf2.import.importHitachiMES()
%   fNIR = pf2.import.importHitachiMES(file)
%   fNIR = pf2.import.importHitachiMES(file, pathname)
%   fNIR = pf2.import.importHitachiMES(file, pathname, channelCheck)
%
% Inputs:
%   file         - Filename or full path to MES file [char | string]
%                  If omitted or empty, a file selection dialog opens.
%                  Files typically contain 'MES' in the filename.
%   pathname     - Directory path if file is just a filename (default: pwd)
%                  Ignored if file contains full path.
%   channelCheck - Run channel quality check GUI after import (default: true)
%                  Set to false to skip interactive quality assessment.
%
% Outputs:
%   fNIR - Standard pf2 fNIRS data structure containing:
%          .raw       - Raw intensity data [T x C double]
%          .time      - Time vector in seconds [T x 1 double]
%          .fs        - Sampling frequency in Hz [double]
%          .markers   - Event markers [M x 4: time, value, index, amplitude]
%          .fchMask   - Channel quality mask [1 x C: 1=good, 0=bad]
%          .info      - Metadata structure containing:
%                       .MESheader      - Raw header fields
%                       .chWavelengths  - Wavelength per channel [2 x C]
%                       .SubjectID      - Subject name from header
%                       .Age            - Subject age (if available)
%                       .Sex            - Subject sex (if available)
%                       .startTime      - Recording start time string
%                       .probename      - Auto-detected probe config
%
% Algorithm:
%   1. Parse header section (tab or comma delimited)
%   2. Extract wavelength info from column headers CH#(wavelength)
%   3. Read data matrix using textscan
%   4. Convert sample indices to time using sampling period
%   5. Extract markers from Mark column
%   6. Auto-detect probe type from channel count
%
% Example:
%   % Import with file dialog
%   data = pf2.import.importHitachiMES();
%
%   % Import specific file
%   data = pf2.import.importHitachiMES('Subject01_MES.csv');
%
%   % Import with explicit path, skip channel check
%   data = pf2.import.importHitachiMES('data.csv', '/path/to/data/', false);
%
% Notes:
%   - Supports both tab-delimited and comma-delimited MES formats
%   - Time offset assumes 10-second baseline period (adjustable via SetT0)
%   - Channel count determines probe config: 44=3x5, 104=3x11
%   - Date/time parsed from header for .t0 if available
%   - Special characters in header fields are sanitized to valid MATLAB names
%
% See also: pf2.import.importSNIRF, pf2.import.importNIRX, pf2.import.importNIR

pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

forceChannelCheck=false;
channelCheckVersion=pf2_base.channelCheckVersion();
for vi_=1:2:numel(varargin)
    if ischar(varargin{vi_}) && strcmpi(varargin{vi_},'ChannelCheckVersion')
        channelCheckVersion=varargin{vi_+1};
    end
end

if(nargin<3) % channel check is on by default with no file
    channelCheck=true;
else
    forceChannelCheck=true; % but if you manually specifiy it is honored
end
    

curdir=cd;

if(nargin<2||isempty(pathname))
    pathname=cd;
end

if nargin < 1 || isempty(file)
  [file, pathname] = uigetfile({'*MES*.*';'*.*'},'Open Hitachi MES file');
  if isequal(file,0)   % selection cancelled
      fNIR = [];
      return;
  end
  filename=fullfile(pathname,file);
  fid = fopen(filename);

elseif ~ischar(file) && ~isstring(file)
  error('pf2:importHitachiMES:badInput', 'Input must be a string representing a filename');
elseif nargin<2
    fid=fopen(file);
    filename=file;
else
    if(isfile(file))
     filename=file;
     fid=fopen(filename);
    else
        
        % Join with a real separator (fullfile), not bracket concatenation,
        % so 'sub.csv' + '/data/subj' does not become '/data/subjsub.csv'.
        filename=fullfile(pathname,file);
        fid=fopen(filename);
    end
end


[filepath,fileroot,ext]=fileparts(filename);

if fid==-1
  error('pf2:importHitachiMES:fileNotFound', 'Data file not found or permission denied');
end
fidCleanup = onCleanup(@() fcloseIfOpen(fid));

fNIR=[];

lineF=fgetl(fid);
lineNum=1;

header=[];

delimiter='\t';

while(~feof(fid)&&(ischar(lineF))&&~strcmp(lineF,'Data'))
    lineSplit=strsplit(lineF,delimiter);
    if(length(lineSplit)>1)
       varField=renameValid(strtrim(lineSplit{1}));
       header.(varField)=strtrim(lineF(length(lineSplit{1})+2:end));
    end
    lineF=fgetl(fid);
    lineNum=lineNum+1;
end

if(isempty(header))
    delimiter=',';
    frewind(fid);
    lineF=fgetl(fid);
    while(~feof(fid)&&(ischar(lineF))&&~strcmp(lineF,'Data'))
        lineSplit=strsplit(lineF,delimiter);
        if(length(lineSplit)>1)
           varField=renameValid(strtrim(lineSplit{1}));
           header.(varField)=strtrim(lineF(length(lineSplit{1})+2:end));
        end
        lineF=fgetl(fid);
        lineNum=lineNum+1;
    end
end

if(isempty(header))
    error('pf2:importHitachiMES:unknownFormat', 'Unknown delimiter or file type');
end


lineF=fgetl(fid);
lineNum=lineNum+1;

header.HeaderInfo=lineF;
lineF=fgetl(fid);
startLineNum=lineNum;
clear fidCleanup;
fid=-1;

dataLineParts=strsplit(header.HeaderInfo,delimiter);

numCols=length(dataLineParts);
timeCol=find(strcmp(dataLineParts,'Time')); %Use Time column to estimate number of columns and remove body movement mark

markCol=find(strcmp(dataLineParts,'Mark'));


fprintf('Importing %s...\n',filename);
fid=fopen(filename,'r');
if fid==-1
  error('pf2:importHitachiMES:reopenFailed', 'Unable to reopen file for data read: %s', filename);
end
fidCleanup = onCleanup(@() fcloseIfOpen(fid));
for i=1:startLineNum
    line=fgetl(fid);  % Figure out the number of columns based on the header
end


f=[]; 
isNum=true(1,numCols);
for i=1:numCols
    if(i==timeCol) % find time segment
        f=[f '%s '];

        isNum(i)=false;
    else
        f=[f '%f '];
    end
end

if(~isempty(f))
    data=textscan(fid,f,'delimiter',delimiter);
    datetimeCol=data{(~isNum)};
    data=horzcat(data{isNum});
else
    disp('Data is empty!');
    data=[];
    datetimeCol=[];
end

clear fidCleanup;
fid=-1;


hMES = data;%importdata(filename,delimiter,startLineNum);

if(~isempty(datetimeCol)) %Searches for first timepoint in data (to add seconds to start time)
   fNIR.info=[];
   timeColData=datetimeCol;

   if(length(datetimeCol)>=1)
    fNIR.info.startTime=timeColData{1};
   else
      warning('Unable to find first sample timepoint in MES file'); 
   end
end


hMES(isnan(hMES(:,1)),:)=[]; %remove nan columns


chWavelengths=[0;0];
wvHeaders=strsplit(header.HeaderInfo,delimiter);
for j=2:length(wvHeaders)
    temp=sscanf(wvHeaders{j},'CH%f(%f)');
    if(~isempty(temp)&&length(temp)==2)
       chWavelengths(:,j)=temp;
    end
end

numCh=size(chWavelengths,2)-1;

mrkIdx=find(hMES(:,markCol)>0);
fNIR.raw=hMES(:,1:(1+numCh));
if(isfield(header,'Sampling_Period_s'))
    s_period=str2double(header.Sampling_Period_s);
    fNIR.time=fNIR.raw(:,1)*s_period-10; % Assumes a 10 second baseline period for offset
     fNIR.raw(:,1)=fNIR.time;
     fNIR.fs=1/s_period;
end
if(isfield(header,'Wave_nm'))
    header.Wave_nm(header.Wave_nm=='''')=[];
   fNIR.info.curWv=str2double(strsplit(header.Wave_nm,delimiter)); 
   numWv=length(fNIR.info.curWv);
else
   error('pf2:importHitachiMES:missingWavelengths', 'Missing number of wavelengths');
end

if(isfield(header,'Date'))
    startDate=header.Date; 
    try
        header.StartDateTime= datetime(startDate,'InputFormat','yyyy/MM/dd HH:mm:ss'); % try to get timestamp with milliseconds
     catch
        header.StartDateTime= datetime(startDate,'InputFormat','yyyy/MM/dd HH:mm'); % else use only regular seconds
     end
    if(~isempty(datetimeCol))
        startTime=datetimeCol{1};
        startTime=datetime(startTime,'InputFormat','HH:mm:ss.SS'); % try to get timestamp with milliseconds
        header.StartDateTime.Minute=startTime.Minute;
        header.StartDateTime.Second=startTime.Second;
    end
end



fNIR.markers=[fNIR.time(mrkIdx),hMES(mrkIdx,markCol),mrkIdx];
fNIR.markers = pf2_base.normalizeMarkers(fNIR.markers);

fNIR.info.MESheader=header;
fNIR.info.chWavelengths=chWavelengths;


if(~isempty(header)&&isfield(header,'Name'))
    fNIR.info.SubjectID=header.Name;
end
if(~isempty(header)&&isfield(header,'Comment'))
    fNIR.info.Comment=header.Comment;
end
    
if(~isempty(header)&&isfield(header,'ID'))
    fNIR.info.Session=header.ID;
end
    
if(~isempty(header)&&isfield(header,'Sex'))
    fNIR.info.Sex=header.Sex;
end

if(~isempty(header)&&isfield(header,'Age'))
    fNIR.info.Age=str2double(header.Age(1:end-1));
end




fprintf('Importing Complete\n');
cd(curdir);

numRawChannels=numCh;

switch(numRawChannels)
    case 44
        fNIR.info.probename='Hitachi_ETG4000_3x5';
    case 104
        fNIR.info.probename='Hitachi_ETG4000_3x11';
    otherwise
        warning('Unidentified Probe\n');
        fNIR.info.probename='Unkown *MES.CSV file';
end

% Attach Device object for self-describing data
try
    fNIR.device = pf2.Device.load(fNIR);
catch
    % Unknown probe — skip device attachment
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


if(channelCheck)
        if(forceChannelCheck && pf2_base.allowChannelCheckGUI())
            if channelCheckVersion == 2
                app = pf2.qc.ChannelCheck(fNIR, 'CalledFromImport', true, 'SkipConfirmation', true);
                if isvalid(app), fNIR = app.OutputData; delete(app); end
            else
                fNIR=probeCheckGUI(fNIR,filename,forceChannelCheck);
            end
        else
            % Non-forced, or the GUI cannot/should not be shown (headless,
            % under test, or disabled): loadExistingMaskOrCheck loads a saved
            % mask if present and defaults all-good rather than blocking on the
            % channel-check GUI.
            fNIR=pf2_base.loadExistingMaskOrCheck(fNIR,filename,channelCheckVersion);
        end
else
   if(~isempty(fmask))
       fNIR.fchMask=fmask;
   else
       fNIR.fchMask=ones(1,numCh/numWv); 
   end
       
end


end



function Name2 = renameValid(Name)

persistent Numbers LowerCases UpperCases

if isempty(Numbers)
    Numbers = arrayfun(@(n) {sprintf('%u',n)},0:9);
    LowerCases = arrayfun(@(n) {char(n+96)},1:26);
    UpperCases = arrayfun(@(n) {char(n+64)},1:26);
end

Name2 = '';
for n = 1:length(Name)
    Character = Name(n);
    switch Character
        case Numbers
        case LowerCases
        case UpperCases
        case {'�','�','�','�','�','�'},     Character = 'A';
        case '�',                           Character = 'AE';
        case '�',                           Character = 'C';
        case {'�','�','�','�'},             Character = 'E';
        case {'�','�','�','�'},             Character = 'I';
        case '�',                           Character = 'N';
        case {'�','�','�','�','�'},         Character = 'O';
        case {'�','�','�','�'},             Character = 'U';
        case '�',                           Character = 'Y';
        case '�',                           Character = '2';
        case '�',                           Character = '3';
        case '�',                           Character = '1_4';
        case '�',                           Character = '1_2';
        case '�',                           Character = '3_4';
        case {'�','�','�','�','�','�'},     Character = 'a';
        case '�',                           Character = 'ae';
        case '�',                           Character = 'c';
        case {'�','�','�','�'},             Character = 'e';
        case {'�','�','�','�'},             Character = 'i';
        case '�',                           Character = 'n';
        case {'�','�','�','�','�'},         Character = 'o';
        case {'�','�','�','�','�'},         Character = 'u';
        case {'�','�'},                     Character = 'y';
        case {' ','''', '-', '_',...
                '(','[','/','\'},         	Character = '_';
        case {'�'},                         Character = 'deg';
        otherwise,                          Character = '' ;
    end
    Name2 = [Name2, Character]; %#ok<AGROW>
end

Name2 = strrep(Name2,'__','_');
if length(Name2) > 1
    if strcmp(Name2(end),'_')
        Name2 = Name2(1:end-1);
    end
end
Name2 = matlab.lang.makeValidName(Name2);

end

function fcloseIfOpen(fid)
    if ~isempty(fid) && isnumeric(fid) && fid > 0
        try
            fclose(fid);
        catch
        end
    end
end
