function [snirfData] = asSNIRF(fNIRcells, filepath, varargin)
% ASSNIRF Export fNIRS data to SNIRF format
%
% Converts pf2 fNIRS data structures to the standardized SNIRF format for
% interoperability with other fNIRS analysis tools (Homer3, MNE-Python,
% FieldTrip, etc.). Generates HDF5-based .snirf files compliant with the
% SNIRF specification v1.1.
%
% Reference:
%   SNIRF format specification: https://github.com/fNIRS/snirf
%
% Syntax:
%   snirfData = pf2.export.asSNIRF(fNIR)                    % GUI save dialog
%   snirfData = pf2.export.asSNIRF(fNIR, filepath)          % Save to path
%   snirfData = pf2.export.asSNIRF(fNIRcells, filepath)     % Multiple runs
%   snirfData = pf2.export.asSNIRF(..., normalizeRaw, stripExtraRawChannels)
%   pf2.export.asSNIRF(allData, 'output/')                  % Batch to directory
%   pf2.export.asSNIRF(allData, 'output/', 'Dir1', 'Group') % With subdirs
%
% Inputs:
%   fNIRcells            - fNIRS data structure or cell array of structures
%                          Each structure should contain .raw, .time, .fs, etc.
%                          Multiple structures create multiple /nirs groups.
%   filepath             - Output file path or directory (optional)
%                          If omitted or empty, opens a save dialog (single/multi-
%                          run struct) or a directory picker (cell-array batch).
%                          Cell array + directory path (no .snirf ext) = batch mode.
%                          Extension .snirf is added if missing in single-file mode.
%   normalizeRaw         - Normalize raw data before export (default: false)
%                          If true, scales data for improved compatibility.
%   stripExtraRawChannels - Remove dark/ambient channels from export (default: false)
%                          Time and marker columns are always removed.
%
% Batch Mode Name-Value Parameters:
%   'Dir1'..'Dir4'           - Info field names mapped to subdirectories
%   'Prefix'                 - Cell array of info field names for filename
%   'NormalizeRaw'           - Normalize raw data (default: false)
%   'StripExtraRawChannels'  - Strip dark/ambient channels (default: false)
%   'Verbose'                - Print progress messages (default: true)
%   'TimeZone'               - Also accepted in single-file mode (see below)
%
% Name-Value Parameters:
%   'TimeZone'  - Time zone of the recording's wall-clock start time (t0),
%                 e.g. 'America/New_York' or '-05:00' (default: ''). Applied
%                 when t0 has no zone of its own; never taken from this
%                 machine. With a zone, MeasurementTime carries its UTC offset
%                 and UnixTime/AcquisitionStartTime are written. Without one,
%                 MeasurementTime has no offset, UnixTime is omitted and
%                 'pf2:asSNIRF:noTimeZone' is warned.
%
% Outputs:
%   snirfData            - Generated SNIRF data structure
%                          Can be used for inspection or further manipulation.
%
% SNIRF Structure Created:
%   /formatVersion       - '1.1'
%   /nirs/               - (or /nirs1/, /nirs2/, etc. for multiple runs)
%       /data/           - Time series data
%           /dataTimeSeries [T x C]
%           /time [T x 1]
%       /probe/          - Probe geometry
%           /sourcePos, /detectorPos, /wavelengths, etc.
%       /metaDataTags/   - Subject and session info. MeasurementDate is
%                          written only from a parsed date (yyyy-MM-dd).
%       /stim/           - Stimulus/marker events [startTime duration value
%                          extras...]. Duration is the marker table's
%                          Duration column as imported. An Amplitude column
%                          that is all 1 (the default) is not written.
%
% Notes:
%   - Creates output directory if it doesn't exist
%   - Uses jsnirfy library for HDF5 writing
%   - Probe geometry requires device config to be loaded
%   - Python compatibility improvements over standard SNIRF writers
%   - filepath is required in headless sessions (pf2_base.isHeadless()): the
%     GUI save/directory dialog cannot be shown, so a missing filepath errors
%     with 'pf2:export:asSNIRF:noPathHeadless' instead of hanging/crashing.
%
% Example:
%   % Export single dataset
%   pf2.export.asSNIRF(processedData, 'subject01.snirf');
%
%   % Export multiple runs in one file
%   pf2.export.asSNIRF({run1, run2, run3}, 'session.snirf');
%
%   % Batch export to directory
%   pf2.export.asSNIRF(allData, 'output/');
%   pf2.export.asSNIRF(allData, 'output/', 'Dir1', 'Group', 'Prefix', {'SubjectID'});
%
%   % Export with GUI file selection
%   snirfStruct = pf2.export.asSNIRF(data);
%
% See also: pf2.import.importSNIRF, pf2.export.asNIR, savesnirf

if(nargin < 1)
    error('pf2:asSNIRF:noData', 'No fnir file specified!');
end

if nargin < 2 || isempty(filepath)
   if pf2_base.isHeadless()
       error('pf2:export:asSNIRF:noPathHeadless', ...
           ['No output filepath was given and this session is headless (no ', ...
            'interactive save/directory dialog available). Pass an explicit ', ...
            'filepath (or output directory for batch export).']);
   end
   if iscell(fNIRcells)
       % Cell array: batch export -> prompt for an output directory.
       filepath = uigetdir('', 'Select output directory for batch SNIRF export');
       if isequal(filepath, 0)   % selection cancelled
           snirfData = [];
           return;
       end
   else
       % Single/multi-run struct: prompt for an output file.
       [filename, path] = uiputfile('*.snirf', 'Save fNIRS data as SNIRF');
       if isequal(filename, 0)   % selection cancelled
           snirfData = [];
           return;
       end
       filepath = fullfile(path, filename);
   end
end

% --- Detect batch mode: cell array + directory path (no .snirf extension) ---
[~, ~, extCheck] = fileparts(filepath);
isBatchMode = iscell(fNIRcells) && ~strcmpi(extCheck, '.snirf');

if isBatchMode
    % Parse batch name-value parameters
    batchOpts = parseBatchOpts(varargin{:});
    paths = pf2_base.buildExportPaths(fNIRcells, filepath, '.snirf', batchOpts);
    n = numel(fNIRcells);
    for i = 1:n
        if batchOpts.Verbose
            fprintf('  Exporting %d/%d: %s\n', i, n, paths{i});
        end
        pf2.export.asSNIRF(fNIRcells{i}, paths{i}, ...
            batchOpts.NormalizeRaw, batchOpts.StripExtraRawChannels, ...
            'TimeZone', batchOpts.TimeZone);
    end
    if batchOpts.Verbose
        fprintf('Batch export complete: %d files written to %s\n', n, filepath);
    end
    snirfData = [];
    return;
end

% --- Single/multi-run mode: parse legacy positional or name-value args ---
normalizeRaw = false;
stripExtraRawChannels = false;
args = varargin;
% Legacy positional: asSNIRF(data, path, true, false)
if ~isempty(args) && (islogical(args{1}) || isnumeric(args{1}))
    normalizeRaw = args{1};
    args(1) = [];
    if ~isempty(args) && (islogical(args{1}) || isnumeric(args{1}))
        stripExtraRawChannels = args{1};
        args(1) = [];
    end
end
p = inputParser;
p.KeepUnmatched = true;
p.addParameter('NormalizeRaw', normalizeRaw, @(x) islogical(x) || isnumeric(x));
p.addParameter('StripExtraRawChannels', stripExtraRawChannels, @(x) islogical(x) || isnumeric(x));
p.addParameter('TimeZone', '', @(x) ischar(x) || isstring(x));
p.parse(args{:});
normalizeRaw = p.Results.NormalizeRaw;
stripExtraRawChannels = p.Results.StripExtraRawChannels;
timeZone = char(p.Results.TimeZone);

[ filepathdir, filename, ext ] = fileparts(filepath);

% Writing .snirf file
if(exist(filepathdir,'dir') ~= 7 && ~isempty(filepathdir))
    mkdir(filepathdir);
end

snirfData = [];

% SNIRF format version - use latest version for best compatibility
snirfData.formatVersion = c2v('1.1');

if(~iscell(fNIRcells) && isstruct(fNIRcells))
    fNIRcells = {fNIRcells};
elseif ~iscell(fNIRcells) || isempty(fNIRcells)
    error('pf2:asSNIRF:invalidInput', 'Invalid fnirs data: Must be a structure or non-empty cell array of structures');
end

curNIR_fieldname = 'nirs';
numNIRS = length(fNIRcells);

for n = 1:numNIRS
    curStruct = fNIRcells{n};
    
    if(numNIRS > 1)
        curNIR_fieldname = ['nirs' num2str(n)];
    end

    curNIRdata = [];

    % Convert info to metadata with enhanced field mapping
    metaDataTags = info2meta(curStruct, timeZone);

    % Build probe structure and measurement list
    [probe, measurementList, probeMetaData, rawMax, forceStrippedChannelsMask] = buildProbe(curStruct);

    % Handle extra channels if needed
    rawDCchannels = strcmp(cellfun(@(x) x, {measurementList.dataTypeLabel}, 'UniformOutput', false), 'raw-DC');
    rawDCdarkChannels = strcmp(cellfun(@(x) x, {measurementList.dataTypeLabel}, 'UniformOutput', false), 'raw-DC-dark');
    extraChannels = ~(rawDCchannels);

    if(stripExtraRawChannels && ~isempty(extraChannels))
        measurementList = measurementList(~extraChannels);
        [uniqueWavelengths, ~, wavelengthIndices] = unique([measurementList.wavelengthIndex]);
        for i = 1:length(measurementList)
            measurementList(i).wavelengthIndex = wavelengthIndices(i);
        end
        probe.wavelengths = probe.wavelengths(uniqueWavelengths);

        % Now remove them from the indicies
        rawDCchannels = rawDCchannels(~extraChannels);
        rawDCdarkChannels = rawDCdarkChannels(~extraChannels);
    end

    % Add probe metadata to general metadata
    probeFields = fieldnames(probeMetaData);
    for p = 1:length(probeFields)
        metaDataTags.(probeFields{p}) = probeMetaData.(probeFields{p});
    end
    
    % Set up data section with time series and measurement list
    data = [];
    data.dataTimeSeries = curStruct.raw(:,forceStrippedChannelsMask);
    
    % Handle time data
    if size(data.dataTimeSeries, 1) == length(curStruct.time)
        data.time = curStruct.time(:)';  % Ensure row vector
    else
        % Create regular time vector if dimensions don't match
        warning('Time vector dimensions do not match data. Creating regular time vector.');
        samplingRate = 1;
        if isfield(curStruct, 'fs') && ~isempty(curStruct.fs)
            samplingRate = curStruct.fs;
        end
        data.time = (0:(size(data.dataTimeSeries, 1)-1))' / samplingRate;
    end
    
    data.measurementList = measurementList;

    if(stripExtraRawChannels && ~isempty(extraChannels))
        data.dataTimeSeries = data.dataTimeSeries(:, ~extraChannels);
    end

    % Add units to measurement list (improves compatibility)
    for k = 1:length(data.measurementList)
        if ~isfield(data.measurementList(k), 'dataUnit') || isempty(data.measurementList(k).dataUnit)
            if strcmp(data.measurementList(k).dataTypeLabel, 'raw-DC')
                data.measurementList(k).dataUnit = c2v('V'); % Or appropriate unit
            elseif strcmp(data.measurementList(k).dataTypeLabel, 'raw-DC-dark')
                data.measurementList(k).dataUnit = c2v('V'); % Or appropriate unit
            end
        end
    end

    % Handle data normalization if requested
    if(normalizeRaw)
        rawDC_channels = rawDCchannels | rawDCdarkChannels;
        
        if(~isnan(rawMax))
            normalizedData = data.dataTimeSeries(:, rawDC_channels) ./ rawMax;
        else
            if(normalizeRaw > 1)
                estimatedRawMax = normalizeRaw;
            else
                estimatedRawMax = nanmax(nanmax(data.dataTimeSeries(:, rawDC_channels)));
                warning('Normalizing to estimated rawmax %i\nIf this is not your intention, please set the normalizeRaw value to match your intended device normalization', estimatedRawMax);
            end       
       
            normalizedData = data.dataTimeSeries(:, rawDC_channels) ./ estimatedRawMax;
            metaDataTags.('RawMax') = c2v(num2str(estimatedRawMax));
        end

        metaDataTags.('Normalized') = c2v('true');
        data.dataTimeSeries(:, rawDC_channels) = normalizedData;
    end

    % Set up stimulus data
    stim = [];

    % Resolve the dataset marker dictionary (code->label) so condition names
    % are serialized even when the markers table carries no label column.
    dictTbl = [];
    if isfield(curStruct, 'info') && isstruct(curStruct.info)
        if isfield(curStruct.info, 'markerDict') && ~isempty(curStruct.info.markerDict)
            dictTbl = pf2_base.normalizeMarkerDict(curStruct.info.markerDict);
        elseif isfield(curStruct.info, 'eventTypes') && ~isempty(curStruct.info.eventTypes)
            dictTbl = pf2_base.normalizeMarkerDict(curStruct.info.eventTypes);
        end
    end

    if isfield(curStruct, 'markers') && ~isempty(curStruct.markers)
        % Check if markers is a table or numeric array
        if istable(curStruct.markers)
            % Canonical marker table: Time, Code, Duration, Amplitude (+extras)
            mt = pf2_base.normalizeMarkers(curStruct.markers);
            times = mt.Time; codes = mt.Code; durs = mt.Duration;

            % Classify extra columns (everything beyond Time/Code/Duration).
            % Numeric/logical extras (e.g. Amplitude, GameScore, isDeviceMarker)
            % are carried as additional numeric stim-data columns labeled with
            % their variable names. Text/categorical extras cannot live in
            % SNIRF's numeric stim matrix, so they are skipped (no error); the
            % first such column, if any, is used to name the stim conditions.
            coreVars = {'Time', 'Code', 'Duration'};
            extraVars = setdiff(mt.Properties.VariableNames, coreVars, 'stable');
            numericExtra = {};
            labelVar = '';
            for v = 1:numel(extraVars)
                col = mt.(extraVars{v});
                if strcmp(extraVars{v}, 'Amplitude') && isnumeric(col) && all(col == 1)
                    % Default amplitude (normalizeMarkers fill); importSNIRF
                    % restores it, so it adds a column without information
                    continue;
                end
                if isnumeric(col) || islogical(col)
                    numericExtra{end+1} = extraVars{v}; %#ok<AGROW>
                elseif isempty(labelVar) && (isstring(col) || iscellstr(col) || iscategorical(col))
                    labelVar = extraVars{v};
                end
            end

            uniqueMarkers = unique(codes);
            for m = 1:length(uniqueMarkers)
                markerIdx = codes == uniqueMarkers(m);
                stimItem = [];

                % Name from a text label column if present, else the dataset
                % dictionary, else the bare code.
                autoName = sprintf('marker%i', uniqueMarkers(m));
                nameStr = autoName;
                if ~isempty(labelVar)
                    lbls = string(mt.(labelVar)(markerIdx));
                    lbls = lbls(~ismissing(lbls));
                    if ~isempty(lbls)
                        nameStr = char(lbls(1));
                    end
                end
                if strcmp(nameStr, autoName)
                    nameStr = dictLabel(dictTbl, uniqueMarkers(m), autoName);
                end
                stimItem.name = c2v(nameStr);

                % SNIRF convention: [startTime, duration, value]
                stimItem.data = [times(markerIdx), durs(markerIdx), codes(markerIdx)];
                stimLabels = {'startTime', 'duration', 'value'};

                % Append numeric extra columns, preserving their names
                for v = 1:numel(numericExtra)
                    stimItem.data = [stimItem.data, ...
                        double(mt.(numericExtra{v})(markerIdx))];
                    stimLabels{end+1} = numericExtra{v}; %#ok<AGROW>
                end
                if numel(stimLabels) > 3
                    % String array -> one 1-D dataLabels dataset (SNIRF spec);
                    % a cell array would be split into dataLabels1..N
                    stimItem.dataLabels = string(stimLabels);
                end

                if m == 1
                    stim = stimItem;
                else
                    stim(m) = stimItem;
                end
            end
        else
            % Handle numeric array format
            [uniqueMarkers, ~, markerIndices] = unique(curStruct.markers(:, 2));
            
            for m = 1:length(uniqueMarkers)
                markerIdx = curStruct.markers(:, 2) == uniqueMarkers(m);
                stimItem = [];
                autoName = sprintf('mrk%i', uniqueMarkers(m));
                stimItem.name = c2v(dictLabel(dictTbl, uniqueMarkers(m), autoName));

                % Standard format: [time, duration, marker value]
                stimItem.data = curStruct.markers(markerIdx, [1, 3, 2]);
                
                % Add dataLabels if more than 3 columns
                if size(curStruct.markers, 2) > 3
                    stimLabels = {'startTime', 'duration', 'value'};
                    % Include amplitude data in SNIRF output
                    stimItem.data = [stimItem.data, curStruct.markers(markerIdx, 4:end)];
                    for col = 4:size(curStruct.markers, 2)
                        if col == 4
                            stimLabels{end+1} = 'amplitude';
                        else
                            stimLabels{end+1} = sprintf('column%d', col);
                        end
                    end
                    stimItem.dataLabels = string(stimLabels);
                end

                if m == 1
                    stim = stimItem;
                else
                    stim(m) = stimItem;
                end
            end
        end
    end
    
    % Add auxiliary data if available
    aux = [];
    if isfield(curStruct, 'Aux') && ~isempty(curStruct.Aux)
        auxFieldNames = fieldnames(curStruct.Aux);
        auxCounter = 0;
        
        for i = 1:length(auxFieldNames)
            auxField = curStruct.Aux.(auxFieldNames{i});
            
            % Handle different aux data formats
            if isstruct(auxField)
                if isfield(auxField, 'data') && ~isempty(auxField.data)
                    auxCounter = auxCounter + 1;
                    auxItem = [];
                    auxItem.name = c2v(auxFieldNames{i});
                    auxItem.dataTimeSeries = auxField.data;
                    
                    % Handle time data
                    if isfield(auxField, 'time')
                        auxItem.time = auxField.time(:)';  % Ensure row vector
                    else
                        auxItem.time = data.time;  % Use main time vector
                    end
                    
                    % Add unit if available
                    if isfield(auxField, 'unit')
                        auxItem.dataUnit = c2v(auxField.unit);
                    else
                        % Try to determine unit from name
                        if contains(lower(auxFieldNames{i}), {'accel'})
                            auxItem.dataUnit = c2v('m/s^2');
                        elseif contains(lower(auxFieldNames{i}), {'gyro'})
                            auxItem.dataUnit = c2v('rad/s');
                        else
                            auxItem.dataUnit = c2v('V');  % Default unit
                        end
                    end
                    
                    if auxCounter == 1
                        aux = auxItem;
                    else
                        aux(auxCounter) = auxItem;
                    end
                end
            elseif isnumeric(auxField) && ~isempty(auxField)
                % Direct numeric data
                auxCounter = auxCounter + 1;
                auxItem = [];
                auxItem.name = c2v(auxFieldNames{i});
                auxItem.dataTimeSeries = auxField;
                auxItem.time = data.time;  % Use main time vector
                
                % Try to determine unit from name
                if contains(lower(auxFieldNames{i}), {'accel'})
                    auxItem.dataUnit = c2v('m/s^2');
                elseif contains(lower(auxFieldNames{i}), {'gyro'})
                    auxItem.dataUnit = c2v('rad/s');
                else
                    auxItem.dataUnit = c2v('V');  % Default unit
                end
                
                if auxCounter == 1
                    aux = auxItem;
                else
                    aux(auxCounter) = auxItem;
                end
            end
        end
    end

    % Add coordinate system info to probe (helpful for spatial interpretation)
    if ~isfield(probe, 'coordinateSystem')
        probe.coordinateSystem = c2v('Other');
        probe.coordinateSystemDescription = c2v('Probe coordinate system');
    end
    
    % Assemble final structure
    curNIRdata.metaDataTags = metaDataTags;
    curNIRdata.probe = probe;
    
    if ~isempty(stim)
        curNIRdata.stim = stim;
    end
    
    curNIRdata.data = data;
    
    if ~isempty(aux)
        curNIRdata.aux = aux;
    end
    
    snirfData.(curNIR_fieldname) = curNIRdata;
end

if(isstring(filepath))
    filepath = char(filepath);
end

% Save the SNIRF file
pf2_base.external.jsnirfy.savesnirf(snirfData, filepath);

fprintf('Successfully exported SNIRF file to: %s\n', filepath);
end

function name = dictLabel(dictTbl, code, fallback)
    % DICTLABEL Look up a code's label in a normalized dictionary table
    %   Returns FALLBACK when the dictionary is empty or has no usable label
    %   for CODE, so callers always get a valid condition name.
    name = fallback;
    if isempty(dictTbl) || ~istable(dictTbl) || height(dictTbl) == 0
        return;
    end
    row = dictTbl(dictTbl.Code == code, :);
    if height(row) > 0
        lbl = string(row.Label(1));
        if ~ismissing(lbl) && strlength(lbl) > 0
            name = char(lbl);
        end
    end
end

function [dt, hasClock] = toDatetime(val)
    % TODATETIME Parse a datetime or ISO-style date/time string; [] if not parseable
    dt = [];
    hasClock = false;
    if isdatetime(val)
        if ~isempty(val) && ~isnat(val(1))
            dt = val(1);
            hasClock = true;
        end
        return;
    end
    if ~(ischar(val) || isstring(val)), return; end
    str = strtrim(char(val));
    fmts = {'yyyy-MM-dd''T''HH:mm:ss.SSS', 'yyyy-MM-dd''T''HH:mm:ss', ...
        'yyyy-MM-dd HH:mm:ss.SSSSSS', 'yyyy-MM-dd HH:mm:ss.SSS', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd'};
    for k = 1:numel(fmts)
        try
            dt = datetime(str, 'InputFormat', fmts{k});
            hasClock = k < numel(fmts);
            return;
        catch
        end
    end
    dt = [];
end

function charOut = c2v(str)
    % Ensure consistent string format for HDF5 compatibility
    % This creates a variable-length string that works with Python's h5py
    if isempty(str)
        charOut = '';
        return;
    elseif isnumeric(str)
        charOut = num2str(str);
        return;
    end
    charOut = char(str);
end

function metaData = info2meta(nirStruct, timeZone)
    % Enhanced metadata conversion with support for all requested fields
    if nargin < 2, timeZone = ''; end
    
    metaData = [];
    
    % Required metadata fields per SNIRF spec
    metaData.TimeUnit = c2v('s');
    metaData.LengthUnit = c2v('mm');
    metaData.FrequencyUnit = c2v('Hz');
    
    % Check if info exists
    if ~isfield(nirStruct, 'info') || isempty(nirStruct.info)
        nirStruct.info = struct();
    end
    
    info = nirStruct.info;

    % Date/time tags are only written from a parsed datetime (ISO 8601);
    % free-text info fields never overwrite them
    t0Tags = {'MeasurementDate', 'MeasurementTime', 'MeasurementTimeZone', ...
        'AcquisitionStartTime', 'UnixTime'};

    % Recording start: t0, else a date/time held in info
    t0 = [];
    hasClock = true;
    if isfield(nirStruct, 't0') && isdatetime(nirStruct.t0) && ~isempty(nirStruct.t0) && ~isnat(nirStruct.t0)
        t0 = nirStruct.t0;
    else
        dateFields = {'StartDateTime', 'MeasurementDate', 'date', 'Date', 'recordingDate'};
        for k = 1:numel(dateFields)
            if isfield(info, dateFields{k}) && ~isempty(info.(dateFields{k}))
                [t0, hasClock] = toDatetime(info.(dateFields{k}));
                if ~isempty(t0), break; end
            end
        end
        if isempty(t0) && isfield(info, 'UnixTime') && ~isempty(info.UnixTime)
            ut = info.UnixTime;
            if ischar(ut) || isstring(ut), ut = str2double(ut); end
            if isfinite(ut)
                t0 = datetime(ut, 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
                hasClock = true;
            end
        end
    end

    if ~isempty(t0)
        % A t0 without a zone is the device's wall-clock time. Its zone comes
        % from the TimeZone option; it is never taken from this machine.
        if isempty(t0.TimeZone) && ~isempty(timeZone)
            try
                t0.TimeZone = timeZone;
            catch e
                error('pf2:asSNIRF:badTimeZone', 'Invalid TimeZone ''%s'': %s', timeZone, e.message);
            end
        end
        metaData.MeasurementDate = c2v(char(datetime(t0, 'Format', 'yyyy-MM-dd')));
        if hasClock
            if isempty(t0.TimeZone)
                metaData.MeasurementTime = c2v(char(datetime(t0, 'Format', 'HH:mm:ss.SSS')));
                warning('pf2:asSNIRF:noTimeZone', ...
                    ['Recording start time has no time zone; MeasurementTime is written ' ...
                     'without a UTC offset and UnixTime is omitted. Pass ''TimeZone'' ' ...
                     '(e.g. ''America/New_York'') to write absolute times.']);
            else
                metaData.MeasurementTime = c2v(char(datetime(t0, 'Format', 'HH:mm:ss.SSSxxx')));
                metaData.MeasurementTimeZone = c2v(t0.TimeZone);
                tStart = 0;
                if isfield(nirStruct, 'time') && ~isempty(nirStruct.time)
                    tStart = min(nirStruct.time);
                end
                metaData.AcquisitionStartTime = c2v(sprintf('%.3f', posixtime(t0 + seconds(tStart))));
                metaData.UnixTime = c2v(sprintf('%.3f', posixtime(t0)));
            end
        end
    end

    % Ensure required SubjectID is present
    if isfield(info, 'SubjectID') && ~isempty(info.SubjectID)
        metaData.SubjectID = c2v(info.SubjectID);
    elseif isfield(info, 'SubjectId') && ~isempty(info.SubjectId)
        metaData.SubjectID = c2v(info.SubjectId);
    elseif isfield(info, 'Subject') && ~isempty(info.Subject)
        metaData.SubjectID = c2v(info.Subject);
    else
        metaData.SubjectID = c2v('unknown');
    end
    
    % Map fields that might have different names 
    fieldMappings = containers.Map();
    fieldMappings('manufacturer') = 'ManufacturerName';
    fieldMappings('devicemanufacturer') = 'ManufacturerName';
    fieldMappings('devicemodel') = 'Model';
    fieldMappings('model') = 'Model';
    fieldMappings('subjectname') = 'SubjectName';
    fieldMappings('name') = 'SubjectName';
    fieldMappings('patientname') = 'SubjectName';
    fieldMappings('dateofbirth') = 'DateOfBirth';
    fieldMappings('dob') = 'DateOfBirth';
    fieldMappings('birthdate') = 'DateOfBirth';
    fieldMappings('acquisitionstarttime') = 'AcquisitionStartTime';
    fieldMappings('scantime') = 'AcquisitionStartTime';
    fieldMappings('studyid') = 'StudyID';
    fieldMappings('study') = 'StudyID';
    fieldMappings('projectid') = 'StudyID';
    fieldMappings('studydescription') = 'StudyDescription';
    fieldMappings('studyinfo') = 'StudyDescription';
    fieldMappings('projectdescription') = 'StudyDescription';
    fieldMappings('accession') = 'AccessionNumber';
    fieldMappings('accessionnumber') = 'AccessionNumber';
    fieldMappings('instance') = 'InstanceNumber';
    fieldMappings('instancenumber') = 'InstanceNumber';
    fieldMappings('calibrationfile') = 'CalibrationFileName';
    fieldMappings('calibration') = 'CalibrationFileName';
    fieldMappings('measurementdate') = 'MeasurementDate';
    fieldMappings('date') = 'MeasurementDate';
    fieldMappings('recordingdate') = 'MeasurementDate';
    fieldMappings('measurementtime') = 'MeasurementTime';
    fieldMappings('recordingtime') = 'MeasurementTime';
    fieldMappings('unixtime') = 'UnixTime';
    fieldMappings('unixtimestamp') = 'UnixTime';
    fieldMappings('lastname') = 'lastName';
    fieldMappings('surname') = 'lastName';
    fieldMappings('middlename') = 'middleName';
    fieldMappings('firstname') = 'firstName';
    fieldMappings('givenname') = 'firstName';
    fieldMappings('sex') = 'sex';
    fieldMappings('gender') = 'sex';
    fieldMappings('mne_coordframe') = 'MNE_coordFrame';
    fieldMappings('coordframe') = 'MNE_coordFrame';
    
    % Handle device info if it exists
    if isfield(info, 'device') && isstruct(info.device)
        if isfield(info.device, 'Manufacturer') && ~isempty(info.device.Manufacturer)
            metaData.ManufacturerName = c2v(info.device.Manufacturer);
        end
        if isfield(info.device, 'Model') && ~isempty(info.device.Model)
            metaData.Model = c2v(info.device.Model);
        end
    end
    
    % Copy all relevant info fields
    infoFields = fieldnames(info);
    for i = 1:length(infoFields)
        fieldName = infoFields{i};
        fieldValue = info.(fieldName);
        
        % Check if this field maps to a requested field
        mappedName = '';
        if isKey(fieldMappings, lower(fieldName))
            mappedName = fieldMappings(lower(fieldName));
        end
        if ismember(mappedName, t0Tags) || ismember(fieldName, t0Tags) || strcmp(fieldName, 'StartDateTime')
            continue;
        end

        % Process field value based on type
        if (isstring(fieldValue) || ischar(fieldValue)) && ~isempty(fieldValue)
            if ~isempty(mappedName)
                metaData.(mappedName) = c2v(fieldValue);
            else
                metaData.(fieldName) = c2v(fieldValue);
            end
        elseif isnumeric(fieldValue) && all(size(fieldValue) == 1) && ~isempty(fieldValue)
            if ~isempty(mappedName)
                metaData.(mappedName) = c2v(num2str(fieldValue));
            else
                metaData.(fieldName) = c2v(num2str(fieldValue));
            end
        elseif isdatetime(fieldValue) && ~isempty(fieldValue)
            if ~isempty(mappedName)
                if strcmp(mappedName, 'DateOfBirth')
                    metaData.(mappedName) = c2v(datestr(fieldValue, 'yyyy-mm-dd'));
                else
                    metaData.(mappedName) = c2v(datestr(fieldValue));
                end
            else
                metaData.(fieldName) = c2v(datestr(fieldValue));
            end
        end
    end
    
    % Process composite name fields if they exist
    if ~isfield(metaData, 'SubjectName') && (isfield(metaData, 'lastName') || isfield(metaData, 'firstName'))
        lastName = '';
        firstName = '';
        middleName = '';
        
        if isfield(metaData, 'lastName')
            lastName = metaData.lastName;
        end
        
        if isfield(metaData, 'firstName')
            firstName = metaData.firstName;
        end
        
        if isfield(metaData, 'middleName')
            middleName = metaData.middleName;
        end
        
        % Construct full name
        if ~isempty(lastName) || ~isempty(firstName)
            if ~isempty(lastName) && ~isempty(firstName)
                if ~isempty(middleName)
                    metaData.SubjectName = c2v(sprintf('%s, %s %s', lastName, firstName, middleName));
                else
                    metaData.SubjectName = c2v(sprintf('%s, %s', lastName, firstName));
                end
            elseif ~isempty(lastName)
                metaData.SubjectName = c2v(lastName);
            else
                metaData.SubjectName = c2v(firstName);
            end
        end
    end
    
    % Add study information if available
    if isfield(info, 'Session') && ~isfield(metaData, 'StudyDescription')
        metaData.StudyDescription = c2v(['Session: ' info.Session]);
    end
    
    % Handle sampling rate if available
    if isfield(nirStruct, 'fs') && ~isempty(nirStruct.fs)
        metaData.SamplingRate = c2v(num2str(nirStruct.fs));
    end
end

function [probe, measurementList, deviceMetaDataTags, rawMax, strippedChannelsMask] = buildProbe(nirStruct)
    % Enhanced probe and measurement list builder
    
    % Initialize default values
    deviceMetaDataTags = [];
    rawMax = nan;
    strippedChannels=[];
    
    if isfield(nirStruct, 'probeinfo')
        probeStruct = nirStruct.probeinfo.Probe{1};
        deviceInfoFields = nirStruct.probeinfo.Info;
    else
        % Attempt to load probe from probe name
        if isfield(nirStruct.info, 'probename')
            probename = nirStruct.info.probename;
            if ~contains(probename, 'cfg')
                probename = sprintf('%s.cfg', probename);
            end
            try
                device = pf2_base.loadDeviceCfg(probename);
                deviceInfoFields = device.Info;
                probeStruct = device.Probe{1};
            catch
                warning('Failed to load probe configuration. Using default probe.');
                device = pf2_base.loadDeviceCfg();
                deviceInfoFields = device.Info;
                probeStruct = device.Probe{1};
            end
        else
            device = pf2_base.loadDeviceCfg();
            deviceInfoFields = device.Info;
            probeStruct = device.Probe{1};
        end
    end

    % Extract device metadata
    if isfield(deviceInfoFields, 'Manufacturer')
        deviceMetaDataTags.ManufacturerName = c2v(deviceInfoFields.Manufacturer);
    end
    if isfield(deviceInfoFields, 'Name')
        deviceMetaDataTags.Model = c2v(deviceInfoFields.Name);
    end
    if isfield(deviceInfoFields, 'RawMax')
        deviceMetaDataTags.RawMax = c2v(num2str(deviceInfoFields.RawMax));
        rawMax = deviceInfoFields.RawMax;
    end
    % Positions are written as stored, so declare the device's unit
    if isfield(deviceInfoFields, 'CoordinateUnits') && ~isempty(deviceInfoFields.CoordinateUnits)
        deviceMetaDataTags.LengthUnit = c2v(deviceInfoFields.CoordinateUnits);
    end

    % Initialize measurement list
    tableCh = probeStruct.TableCh;

    % Wavelength handling
    if isfield(probeStruct, 'Wavelength')
        wvList = probeStruct.Wavelength;
        wvI = probeStruct.wvI;
    else
        [wvList, ~, wvI] = unique(tableCh.Wavelength);
    end
    
    % Handle dark channels (add a 0 nm entry only when a dark channel needs it)
    darkIdx = find(wvList == 0, 1);
    if isempty(darkIdx) && any(tableCh.isDark)
        wvList(end+1) = 0;
        darkIdx = length(wvList);
    end

    invalidWv = isnan(wvI);

    measurementList=[];
    
    % Build measurement list with enhanced info for each channel
    for i = 1:size(nirStruct.raw, 2)
        measurement = [];
        curCh = tableCh(i, :);

        if curCh.isTime(1)
            strippedChannels=[strippedChannels;i];
            continue;
        elseif curCh.isMarker(1)
            strippedChannels=[strippedChannels;i];
            continue;
        elseif curCh.isDark(1)
            measurement.dataType = 1; 
            measurement.dataTypeIndex = 1;
            measurement.dataTypeLabel = c2v('raw-DC-dark');
            measurement.detectorIndex = tableCh.DetectorIndex(i);
            measurement.sourceIndex = tableCh.SourceIndex(i);
            if(invalidWv(i))
                warning('This channel has an invalid wavelength')
                measurement.wavelengthIndex = nan;
            else
                measurement.wavelengthIndex = wvI(i);
            end
            measurement.wavelengthActual = wvList(darkIdx);
            measurement.dataUnit = c2v('au');
        else
            measurement.dataType = 1; 
            measurement.dataTypeIndex = 1;
            measurement.dataTypeLabel = c2v('raw-DC');
            measurement.detectorIndex = tableCh.DetectorIndex(i);
            measurement.sourceIndex = tableCh.SourceIndex(i);
            if(invalidWv(i))
                warning('This channel has an invalid wavelength')
                measurement.wavelengthIndex = nan;
                measurement.wavelengthActual = nan;
            else
                measurement.wavelengthIndex = wvI(i);
                measurement.wavelengthActual = wvList(measurement.wavelengthIndex);
            end
            measurement.dataUnit = c2v('au');
        end
      
        measurementList = [measurementList; measurement];
    end

    strippedChannelsMask = true(1, size(nirStruct.raw, 2));
    if(~isempty(strippedChannels))
        strippedChannelsMask(strippedChannels)=false;
    end

    % Build probe structure
    probe = [];

    % Extract 2D/3D positions aligned with SNIRF detectorIndex/sourceIndex
    % semantics: row k must be the position of detector/source k so that
    % measurementList references resolve correctly. When DetPos/SrcPos are
    % optode-indexed (height == TableOpt), compress by DetIdx/SrcIdx value
    % and pad missing IDs with NaN (devices with non-contiguous numbering,
    % e.g., merged-probe configs, otherwise produce scrambled positions).
    if ~isfield(probeStruct, 'DetPos') || ~isfield(probeStruct, 'SrcPos')
        % Layout-only device (grid montage, no physical optode coordinates):
        % SNIRF has no place for a schematic grid, so write empty geometry.
        warning('pf2:asSNIRF:noGeometry', ...
            ['Device has no optode coordinates (layout-only); writing empty ' ...
             'source/detector positions to SNIRF.']);
        probe.detectorPos2D = zeros(0, 2);
        probe.detectorPos3D = zeros(0, 3);
        probe.sourcePos2D   = zeros(0, 2);
        probe.sourcePos3D   = zeros(0, 3);
    elseif height(probeStruct.DetPos) == height(probeStruct.SrcPos) && ...
            height(probeStruct.TableOpt) == height(probeStruct.DetPos)
        detIds = probeStruct.TableOpt.DetIdx;
        srcIds = probeStruct.TableOpt.SrcIdx;

        detAll2D = table2array(probeStruct.DetPos(:, {'x_2d', 'y_2d'}));
        detAll3D = table2array(probeStruct.DetPos(:, {'x', 'y', 'z'}));
        srcAll2D = table2array(probeStruct.SrcPos(:, {'x_2d', 'y_2d'}));
        srcAll3D = table2array(probeStruct.SrcPos(:, {'x', 'y', 'z'}));

        maxDet = max(detIds(detIds > 0 & ~isnan(detIds)));
        maxSrc = max(srcIds(srcIds > 0 & ~isnan(srcIds)));
        if isempty(maxDet), maxDet = 0; end
        if isempty(maxSrc), maxSrc = 0; end

        probe.detectorPos2D = nan(maxDet, 2);
        probe.detectorPos3D = nan(maxDet, 3);
        probe.sourcePos2D   = nan(maxSrc, 2);
        probe.sourcePos3D   = nan(maxSrc, 3);

        for d = unique(detIds(:))'
            if d <= 0 || isnan(d), continue; end
            idx = find(detIds == d, 1);
            probe.detectorPos2D(d, :) = detAll2D(idx, :);
            probe.detectorPos3D(d, :) = detAll3D(idx, :);
        end
        for s = unique(srcIds(:))'
            if s <= 0 || isnan(s), continue; end
            idx = find(srcIds == s, 1);
            probe.sourcePos2D(s, :) = srcAll2D(idx, :);
            probe.sourcePos3D(s, :) = srcAll3D(idx, :);
        end
    else
        probe.detectorPos2D = table2array(probeStruct.DetPos(:, {'x_2d', 'y_2d'}));
        probe.detectorPos3D = table2array(probeStruct.DetPos(:, {'x', 'y', 'z'}));
        probe.sourcePos2D   = table2array(probeStruct.SrcPos(:, {'x_2d', 'y_2d'}));
        probe.sourcePos3D   = table2array(probeStruct.SrcPos(:, {'x', 'y', 'z'}));
    end

    % Include landmark positions if available
    if isfield(probeStruct, 'landmarkPos3D')
        probe.landmarkPos3D = probeStruct.landmarkPos3D;
    end
    if isfield(probeStruct, 'landmarkLabels')
        probe.landmarkLabels = probeStruct.landmarkLabels;
    end
    
    % Add source and detector labels if available
    if isfield(probeStruct, 'SrcPos') && isfield(probeStruct.SrcPos, 'Label')
        probe.sourceLabels = probeStruct.SrcPos.Label;
    end
    if isfield(probeStruct, 'DetPos') && isfield(probeStruct.DetPos, 'Label')
        probe.detectorLabels = probeStruct.DetPos.Label;
    end
    
    % Add coordinate system info
    probe.coordinateSystem = c2v('Other');
    probe.coordinateSystemDescription = c2v('Probe-specific coordinate system');
     
    % Add wavelengths
    probe.wavelengths = wvList(~isnan(wvList));
end


function opts = parseBatchOpts(varargin)
% Parse batch export name-value parameters
    p = inputParser;
    p.addParameter('Dir1', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir2', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir3', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Dir4', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Prefix', {}, @iscell);
    p.addParameter('NormalizeRaw', false, @(x) islogical(x) || isnumeric(x));
    p.addParameter('StripExtraRawChannels', false, @islogical);
    p.addParameter('Verbose', true, @islogical);
    p.addParameter('TimeZone', '', @(x) ischar(x) || isstring(x));
    p.parse(varargin{:});
    opts = p.Results;
end