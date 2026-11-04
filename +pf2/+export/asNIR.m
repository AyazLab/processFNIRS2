function [ ] = asNIR( fNIRstruct, filepath, varargin )
% ASNIR Export fNIRS data to fNIR Devices/Biopac .nir format
%
% Writes a pf2 fNIRS data structure back out as the fNIR Devices/COBI Studio
% .nir text format, along with its companion marker (.mrk) and log (.log)
% files. Useful for constructing artificial .nir files for later analysis or
% for round-tripping data through tools that expect the native fNIR format.
% A cell array of structs can be batch-exported to a directory.
%
% Reference:
%   fNIR Devices / COBI Studio .nir text file format.
%
% Syntax:
%   pf2.export.asNIR(fNIRstruct)                 % GUI save dialog
%   pf2.export.asNIR(fNIRstruct, filepath)       % Write to a specific path
%   pf2.export.asNIR(allData, 'output/')         % Batch to a directory
%   pf2.export.asNIR(allData, 'output/', Name, Value, ...)
%
% Inputs:
%   fNIRstruct - fNIRS data structure (.raw, .time, .markers, .info) or a
%                cell array of such structures for batch export.
%   filepath   - Output .nir file path, or a directory path for batch export
%                (optional). If omitted or empty, a save dialog opens (single
%                mode) or a directory picker opens (batch/cell-array mode).
%
% Name-Value Parameters (batch mode only):
%   'Dir1'..'Dir4' - Info field names mapped to subdirectory levels
%   'Prefix'       - Cell array of info field names used to build filenames
%   'Verbose'      - Print progress messages (default: true)
%
% Outputs:
%   (none) - Writes .nir, .mrk, and .log files to disk.
%
% Algorithm:
%   1. In batch mode, build per-element paths and recurse on each struct.
%   2. Write the .nir header (start time, codes, gains) then raw samples.
%   3. Write the companion .mrk marker file from the markers table.
%   4. Write the companion .log file from .info metadata.
%
% Example:
%   % Export a processed sample dataset to a .nir file
%   data = pf2.import.sampleData();
%   pf2.export.asNIR(data, 'sample_out.nir');
%
%   % Batch export a cell array to a directory with subdir mapping
%   pf2.export.asNIR(allData, 'output/', 'Dir1', 'Group', 'Prefix', {'SubjectID'});
%
% Notes:
%   - filepath is required in headless sessions (pf2_base.isHeadless()): the
%     GUI save/directory dialog cannot be shown, so a missing filepath errors
%     with 'pf2:export:asNIR:noPathHeadless' instead of hanging/crashing.
%
% See also: pf2.export.asSNIRF, pf2.export.export, pf2.import.importNIR

if(nargin<1)
    error('pf2:asNIR:noData', 'No fnirs specified!');
end

% --- Batch mode: cell array input ---
if iscell(fNIRstruct)
    if nargin < 2 || isempty(filepath)
        if pf2_base.isHeadless()
            error('pf2:export:asNIR:noPathHeadless', ...
                ['No output directory was given and this session is headless ', ...
                 '(no interactive directory dialog available). Pass an explicit ', ...
                 'output directory for batch export.']);
        end
        % No directory given: prompt for an output folder for the batch.
        filepath = uigetdir('', 'Select output directory for batch .nir export');
        if isequal(filepath, 0)   % selection cancelled
            return;
        end
    end
    opts = parseBatchOpts(varargin{:});
    paths = pf2_base.buildExportPaths(fNIRstruct, filepath, '.nir', opts);
    n = numel(fNIRstruct);
    for i = 1:n
        if opts.Verbose
            fprintf('  Exporting %d/%d: %s\n', i, n, paths{i});
        end
        pf2.export.asNIR(fNIRstruct{i}, paths{i});
    end
    if opts.Verbose
        fprintf('Batch export complete: %d files written to %s\n', n, filepath);
    end
    return;
end

if nargin<2 || isempty(filepath)
   if pf2_base.isHeadless()
       error('pf2:export:asNIR:noPathHeadless', ...
           ['No output filepath was given and this session is headless (no ', ...
            'interactive save dialog available). Pass an explicit filepath.']);
   end
   [filename, path]=uiputfile('*.nir', 'Save fNIRS data as .nir');
   if isequal(filename, 0)   % selection cancelled
       return;
   end
   filepath=fullfile(path, filename);
end

[ filepathdir , filename , ext ] = fileparts( filepath ) ;

mrkFilePath= strjoin([string(filepathdir) '/' string(filename) '.mrk'],'');
logFilePath= strjoin([string(filepathdir) '/' string(filename) '.log'],'');


% Writing .NIR file

if(exist(filepathdir,'dir')~=7)
    mkdir(filepathdir);
end

 fid=fopen(filepath,'wt');

 if(fid<0)
    error('pf2:asNIR:writeFailed', 'Unable to access file for writing!');
 end

 fprintf(fid,'fnirUSB.dll log file\n');
 
 fprintf(fid,'Start Time:\t');
 if(isfield(fNIRstruct,'t0'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.t0,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 elseif(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&isfield(fNIRstruct.info.header,'StartDateTime'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.info.header.StartDateTime,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 else
    fprintf(fid,'Wed Jan 1 1:01:01 2022\n');
 end

fprintf(fid,'\n');


if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'startCode'))
        startCode=fNIRstruct.info.header.startCode;
    fprintf(fid,'Start Code:\t%.6f\t%i\n',startCode,startCode*1000);
else
 fprintf(fid,'Start Code:\t	9999.999999	99999999\n');
end

if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'freqCode'))
        freqCode=fNIRstruct.info.header.freqCode;
    fprintf(fid,'Freq Code:\t%.6f\n',freqCode);
else
 fprintf(fid,'Freq Code:\t	99999999.999999\n');
end

if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'current'))
        current=fNIRstruct.info.header.current;
    fprintf(fid,'Current:\t%.0f\n',current);
else
 fprintf(fid,'Current:\t	99\n');
end

if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'gains'))
        gains=fNIRstruct.info.header.gains;
    fprintf(fid,'Gains:\t%.0f\n',gains);
else
 fprintf(fid,'Gains:\t99\n');
end

 fprintf(fid,'Other:\tnone\n');
 
 fprintf(fid,'-2\tBaseline Started\n');


 arr=fNIRstruct.raw;
 numLines=size(arr,1);
 numCol=size(arr,2);
 for x=1:numLines
     fprintf(fid,'%.3f',fNIRstruct.time(x,1)); 
    for y=2:numCol
       fprintf(fid,'\t%.2f',arr(x,y)); 
    end
     fprintf(fid,'\n');
     if(x==20)
        fprintf(fid,'-3\tBaseline values\n');
            fprintf(fid,'0'); 
            for y=2:numCol
               fprintf(fid,'\t%.2f',nanmean(arr(1:10,y))); 
            end
             fprintf(fid,'\n');
        fprintf(fid,'-4\tBaseline end\n');
     end
 end
 
 fprintf(fid,'-1\tDevice Stopped\n');
 fclose(fid);
 fprintf('File successfully written to: %s\n',filepath);


% Writing Marker file

fid=fopen(mrkFilePath,'wt');
 fprintf(fid,'fnirUSB.dll marker file\n');
 fprintf(fid,'Listening from SomePORT port\n');
 
 fprintf(fid,'Start Time:\t');
 if(isfield(fNIRstruct,'t0'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.t0,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 elseif(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&isfield(fNIRstruct.info.header,'StartDateTime'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.info.header.StartDateTime,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 else
    fprintf(fid,'Wed Jan 1 1:01:01 2022\n');
 end



fprintf(fid,'\n');

if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'startCode'))
        startCode=fNIRstruct.info.header.startCode;
    fprintf(fid,'Start Code:\t%.6f\t%i\n',startCode,startCode*1000);
else
 fprintf(fid,'Start Code:\t	9999.999999	99999999\n');
end

if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'freqCode'))
        freqCode=fNIRstruct.info.header.freqCode;
    fprintf(fid,'Freq Code:\t%.6f\n',freqCode);
else
    fprintf(fid,'Freq Code:\t	99999999.999999\n');
end

 mrkOut=pf2_base.normalizeMarkers(fNIRstruct.markers);
 if(ismember('MarkerSource',mrkOut.Properties.VariableNames))
     mrkOut.MarkerSource=[]; % import bookkeeping (which .mrk file), not a marker column
 end
 arr=pf2_base.markersToArray(mrkOut);
 numLines=size(arr,1);
 numCol=size(arr,2);
 for x=1:numLines
     fprintf(fid,'%.3f',arr(x,1)); 
    for y=2:numCol
        if(rem(arr(x,y),1)==0)
            fprintf(fid,'\t%.0f',arr(x,y));
        else
            fprintf(fid,'\t%.3f',arr(x,y));
        end
    end
     fprintf(fid,'\n');
   
 end
 fclose(fid);
 fprintf('File successfully written to: %s\n',mrkFilePath);


 if(length(fNIRstruct.info)>1)
    fNIRstruct.info=fNIRstruct.info{1};
 end


% Writing Log file

fid=fopen(logFilePath,'wt');
 fprintf(fid,'COBI log file 1.1\n');
 fprintf(fid,'Current Device:\tfnirUSB.dll\n');
 fprintf(fid,'Current Filter Module:\tFilters are OFF\n');
 
  fprintf(fid,'Start Time:\t');
 if(isfield(fNIRstruct,'t0'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.t0,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 elseif(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&isfield(fNIRstruct.info.header,'StartDateTime'))
    fprintf(fid,'%s\n',datestr(fNIRstruct.info.header.StartDateTime,'ddd mmm DD hh:MM:ss.FFF yyyy'));
 else
    fprintf(fid,'Wed Jan 1 1:01:01 2022\n');
 end



fprintf(fid,'\n\n\n');

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'Experimenter'))
        Experimenter=fNIRstruct.info.Experimenter;
    fprintf(fid,'Experimenter:\n%s\n\n',Experimenter);
else
 fprintf(fid,'Experimenter:\n\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'SubjectID'))
        SubjectID=fNIRstruct.info.SubjectID;
    fprintf(fid,'SubjectID:\n%s\n\n',SubjectID);
else
 fprintf(fid,'SubjectID:\n\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'log_info')&&isfield(fNIRstruct.info.log_info,'Description'))
        descrip=fNIRstruct.info.log_info.Description;
    fprintf(fid,'Description:\n%s\n\n',descrip);
else
 fprintf(fid,'Description:\n\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'log_info')&&isfield(fNIRstruct.info.log_info,'SubjectInfo'))
        subInfo=fNIRstruct.info.log_info.SubjectInfo;
    fprintf(fid,'Subject Info:\n%s\n\n',subInfo);
else
 fprintf(fid,'Subject Info:\n\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'log_info')&&isfield(fNIRstruct.info.log_info,'Comments'))
        comments=fNIRstruct.info.log_info.Comments;
    fprintf(fid,'Comments:\n%s\n - Generated by Export from processFNIRS2\n\n',comments);
else
 fprintf(fid,'Comments:\n - Generated by Export from processFNIRS2\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'log_info')&&isfield(fNIRstruct.info.log_info,'Flagged'))
        Flagged=fNIRstruct.info.log_info.Flagged;
    fprintf(fid,'Flagged:\n%s\n\n',Flagged);
else
 fprintf(fid,'Flagged:\n\n\n');
end

if(isfield(fNIRstruct,'info')&&...
    isfield(fNIRstruct.info,'probename'))
        probename=fNIRstruct.info.probename;
    fprintf(fid,'ProbeName:\n%s\n\n',probename);
else
 fprintf(fid,'ProbeName:Unknown\n\n\n');
end

 if(isfield(fNIRstruct,'info')&&isfield(fNIRstruct.info,'header')&&...
    isfield(fNIRstruct.info.header,'Time'))
        timestamp=fNIRstruct.info.header.Time;
    fprintf(fid,'Original Start Time:\t');
    for t=1:length(timestamp)
        fprintf(fid,'%s ',timestamp{t});
    end
    fprintf(fid,'\n');   
else
 fprintf(fid,'Original Start Time:\tUnknown\n');
end

 fprintf(fid,'Finalized Successfully');

 fclose(fid);
 fprintf('File successfully written to: %s\n',logFilePath);


end


function opts = parseBatchOpts(varargin)
% Parse batch export name-value parameters
    p = inputParser;
    p.addParameter('Dir1', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir2', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir3', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir4', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Prefix', {}, @iscell);
    p.addParameter('Verbose', true, @islogical);
    p.parse(varargin{:});
    opts = p.Results;
end
