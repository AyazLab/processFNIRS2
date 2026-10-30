function [fNIR] = importSNIRF(filepath, channelCheck, varargin)
% IMPORTSNIRF Import fNIRS data from SNIRF format files
%
% Reads fNIRS data stored in the Shared Near Infrared Spectroscopy Format
% (SNIRF), a standardized HDF5-based file format for fNIRS data. The SNIRF
% format enables interoperability between different fNIRS analysis software
% packages. This function extracts raw intensity data, probe geometry,
% stimulus markers, auxiliary data, and metadata from SNIRF files.
%
% Reference:
%   SNIRF Specification v1.1 (2023). Shared Near Infrared Spectroscopy
%   Format. https://github.com/fNIRS/snirf
%
% Syntax:
%   fNIR = pf2.import.importSNIRF()
%   fNIR = pf2.import.importSNIRF(filepath)
%   fNIR = pf2.import.importSNIRF(filepath, channelCheck)
%   fNIR = pf2.import.importSNIRF(filepath, channelCheck, Name, Value, ...)
%
% Inputs:
%   filepath     - Path to the SNIRF file [char | string]
%                  If omitted or empty, a file selection dialog opens.
%                  Supports both .snirf (HDF5) and .jsnirf (JSON) formats.
%   channelCheck - Run channel quality check GUI after import (default: true)
%                  Set to false to skip interactive quality assessment.
%   varargin     - Additional name-value pairs passed to loadsnirf()
%                  See pf2_base.external.jsnirfy.loadsnirf for options.
%
% Outputs:
%   fNIR - Standard pf2 fNIRS data structure containing:
%          .raw       - Raw intensity data [T x C double]
%          .time      - Time vector in seconds [T x 1 double]
%          .fs        - Sampling frequency in Hz [double]
%          .markers   - Event markers [M x 4: time, value, duration, amplitude]
%          .fchMask   - Channel quality mask [1 x C: 1=good, 0=bad]
%          .info      - Metadata from SNIRF metaDataTags
%                       .eventTypes - (if BIDS events.tsv exists) cell array
%                                     {code, 'Label'; ...} mapping value to trial_type
%          .t0        - Recording start datetime (if available)
%          .probeinfo - Device and probe geometry structure
%          .Aux       - Auxiliary data (if present in file)
%
% Example:
%   % Import with file dialog and channel check
%   data = pf2.import.importSNIRF();
%
%   % Import specific file, skip channel check
%   data = pf2.import.importSNIRF('subject01.snirf', false);
%
%   % Process imported data
%   processed = processFNIRS2(data);
%
% Notes:
%   - Normalized data is automatically de-normalized if RawMax is available
%   - Optode positions are converted to mm internally (cm input is multiplied
%     by 10); source-detector distances (TableOpt.SD) are stored in cm to match
%     the toolbox convention (bvoxy/Beer-Lambert and other import paths)
%   - Short-separation channels (SD < 2 cm, i.e. ~20 mm) are automatically detected
%   - Probe layout is automatically generated from 3D optode positions
%   - BIDS events.tsv sidecar is auto-detected alongside the SNIRF file.
%     When present, the trial_type-to-value mapping is stored in
%     .info.eventTypes for automatic block labeling by defineBlocks.
%
% See also: pf2.import.importNIR, pf2.import.importNIRX, pf2.export.asSNIRF,
%           pf2_base.external.jsnirfy.loadsnirf

pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

if nargin < 2
   channelCheck = true;
   forceChannelCheck = false;
else
   forceChannelCheck = true;
end

channelCheckVersion = pf2_base.channelCheckVersion();
ccvIdx = [];
for vi_ = 1:2:numel(varargin)
    if ischar(varargin{vi_}) && strcmpi(varargin{vi_}, 'ChannelCheckVersion')
        channelCheckVersion = varargin{vi_+1};
        ccvIdx = [vi_, vi_+1]; %#ok<AGROW>
    end
end
% Remove ChannelCheckVersion from varargin before passing to loadsnirf
if ~isempty(ccvIdx)
    varargin(ccvIdx) = [];
end

includeSSchannels = true;
buildProbeLayout = true;

% Handle file selection if needed (no path given, or an empty placeholder)
if nargin < 1 || isempty(filepath)
   [filename, pathname] = uigetfile({'*.snirf;*.jsnirf','snirf files (*.snirf,*.jsnirf)';'*.*','All files (*.*)'},'Open SNIRF file');
   if isequal(filename, 0) || isequal(pathname, 0)
       error('pf2:importSNIRF:selectionCanceled', 'File selection canceled.');
   end
   filepath = fullfile(pathname, filename);
elseif ~ischar(filepath) && ~isstring(filepath)
   error('pf2:importSNIRF:badInput', 'Input must be a string representing a filename');
end

% Load SNIRF data using jsnirfy loader
try
    data = pf2_base.external.jsnirfy.loadsnirf(filepath, varargin{:});
catch e
    error('pf2:importSNIRF:loadFailed', 'Failed to load SNIRF file: %s', e.message);
end

if ~isfield(data, 'nirs')
    error('pf2:importSNIRF:noNirsStruct', 'No nirs struct contained in file');
end

% Initialize fNIR structure
fNIR = [];

% Process metadata
metaDataTags = stripStruct(data.nirs.metaDataTags);

% Handle markers/stimulus data
if isfield(data.nirs, 'stim') && ~isempty(data.nirs.stim)
    markerTable = pf2_base.normalizeMarkers([]);   % empty canonical table
    stimDict = cell(0, 2);                          % code->label from stim names
    stimArray = data.nirs.stim;

    for m = 1:length(stimArray)
        curStim = stimArray(m);

        if ~isfield(curStim, 'data') || isempty(curStim.data)
            continue;
        end

        % Standard SNIRF stim data is [startTime, duration, value, ...].
        % Map columns to the canonical table by dataLabels when present so
        % extra columns (e.g. amplitude, GameScore) keep their names; fall
        % back to positional order otherwise.
        T = stimToTable(curStim);
        if isempty(T); continue; end
        markerTable = pf2_base.mergeMarkers(markerTable, T);

        % Capture a code->label mapping from the stim condition name. asSNIRF
        % writes a meaningful label as the condition name (falling back to an
        % auto-generated marker<code>/mrk<code>); keep only the meaningful ones
        % so labels survive an asSNIRF round-trip via the marker dictionary.
        if isfield(curStim, 'name') && ~isempty(curStim.name)
            nm = strtrim(char(string(curStim.name)));
            codesHere = unique(T.Code(~isnan(T.Code)));
            for ci = 1:numel(codesHere)
                cval = codesHere(ci);
                auto1 = sprintf('marker%g', cval);
                auto2 = sprintf('mrk%g', cval);
                if ~isempty(nm) && ~strcmp(nm, auto1) && ~strcmp(nm, auto2)
                    stimDict(end+1, :) = {cval, nm}; %#ok<AGROW>
                end
            end
        end
    end

    if height(markerTable) > 0
        markerTable = sortrows(markerTable, 'Time');
    end
    fNIR.markers = markerTable;
else
    fNIR.markers = [];
    stimDict = cell(0, 2);
end
fNIR.markers = pf2_base.normalizeMarkers(fNIR.markers);

% Load BIDS events.tsv sidecar (always check for eventTypes mapping)
if isempty(fNIR.markers) || size(fNIR.markers, 1) == 0
    [fNIR.markers, bidsEventTypes] = loadBIDSevents(filepath);
    fNIR.markers = pf2_base.normalizeMarkers(fNIR.markers);
else
    [~, bidsEventTypes] = loadBIDSevents(filepath);
end

% Extract nirs
nirs = data.nirs;

% Extract main data
data = nirs.data;

% Process measurement list
if ~isfield(data, 'measurementList') || isempty(data.measurementList)
    error('pf2:importSNIRF:noMeasurementList', 'No measurement list found in SNIRF file');
end

% Convert measurement list to table for easier handling
measurementList = struct2table(data.measurementList);

% Add dataTypeLabel column if not present (some SNIRF files use numeric dataType only)
if ~ismember('dataTypeLabel', measurementList.Properties.VariableNames)
    nML = height(measurementList);
    labels = repmat({''}, nML, 1);
    if ismember('dataType', measurementList.Properties.VariableNames)
        % SNIRF spec: dataType=1 → CW amplitude (raw intensity)
        for mi = 1:nML
            switch measurementList.dataType(mi)
                case 1,     labels{mi} = 'CW_amplitude';
                case 51,    labels{mi} = 'raw-DC';
                case 99999, labels{mi} = 'processed';
                otherwise,  labels{mi} = sprintf('type_%d', measurementList.dataType(mi));
            end
        end
    end
    measurementList.dataTypeLabel = labels;
end

% Handle normalized data
if isfield(metaDataTags, 'Normalized') && ...
   (strcmpi(metaDataTags.Normalized, '1') || strcmpi(metaDataTags.Normalized, 'true'))
    if isfield(metaDataTags, 'RawMax')
        % Find all raw DC channels (both normal and dark)
        rawDC_channels = contains(cat(1, measurementList.dataTypeLabel), 'raw-DC');
        rawMax = str2double(metaDataTags.RawMax);
        
        % De-normalize by multiplying by rawMax
        data.dataTimeSeries(:, rawDC_channels) = data.dataTimeSeries(:, rawDC_channels) * rawMax;
    else
        warning('Data is normalized but unknown max value, cannot be restored to original state');
    end
end

% Set raw data
fNIR.raw = data.dataTimeSeries;

% Initialize device structure
device = [];

% Handle time data
if isfield(data, 'time')
    % Ensure time is a column vector [T x 1]
    fNIR.time = data.time(:);
    
    % Calculate sampling rate from time data
    fNIR.fs = 1/nanmedian(diff(fNIR.time));
else
    % Create time vector if not available
    warning('No time data found. Creating time vector with default sampling rate.');
    fNIR.fs = 10; % Default sampling rate
    fNIR.time = (0:(size(fNIR.raw, 1)-1))' / fNIR.fs;
end

if (isfield(metaDataTags,'Age') && ~isnumeric(metaDataTags.Age))
    metaDataTags.Age = str2double(metaDataTags.Age);
end

% Set metadata
fNIR.info = metaDataTags;

% Build the canonical marker dictionary. Stim condition names provide a
% code->label mapping (so labels survive an asSNIRF round-trip); a BIDS
% events.tsv sidecar, when present, takes precedence and is also retained as
% eventTypes for back-compat.
combinedDict = [];
if ~isempty(stimDict)
    combinedDict = pf2_base.normalizeMarkerDict(stimDict);
end
if ~isempty(bidsEventTypes)
    fNIR.info.eventTypes = bidsEventTypes;
    bidsDict = pf2_base.normalizeMarkerDict(bidsEventTypes);
    if isempty(combinedDict)
        combinedDict = bidsDict;
    else
        combinedDict = pf2_base.mergeMarkerDict(bidsDict, combinedDict);
    end
end
if ~isempty(combinedDict) && height(combinedDict) > 0
    fNIR.info.markerDict = combinedDict;
end

% Device config
device.Info.TimeIsSampleCount = 0;

% Get probe information
probeInfo = nirs.probe;

% Handle length unit conversion if needed (convert to mm internally)
scaleFactor = 1;
if isfield(metaDataTags, 'LengthUnit')
    % Special case: CapTrak stores in microns (μm) despite metadata saying 'm'
    coordSystem = '';
    if isfield(metaDataTags, 'CoordinateSystem')
        coordSystem = metaDataTags.CoordinateSystem;
    end

    if strcmpi(coordSystem, 'CapTrak')
        % CapTrak: coordinates are in microns, convert to mm
        scaleFactor = 0.001;  % μm to mm: divide by 1000
    else
        % Standard handling based on declared LengthUnit
        switch lower(metaDataTags.LengthUnit)
            case 'm'
                scaleFactor = 1000;
            case 'cm'
                scaleFactor = 10;
            case 'mm'
                scaleFactor = 1;
            case 'um'
                scaleFactor = 0.001;  % micrometers to mm
            otherwise
                scaleFactor = 1;
        end
    end
end

if scaleFactor ~= 1
    probeInfo.detectorPos3D = probeInfo.detectorPos3D * scaleFactor;
    probeInfo.sourcePos3D = probeInfo.sourcePos3D * scaleFactor;
    if isfield(probeInfo, 'landmarkPos3D')
        probeInfo.landmarkPos3D = probeInfo.landmarkPos3D * scaleFactor;
    end
end

% Handle timestamp data
if isfield(metaDataTags, 'UnixTime')
    unixTime = str2double(metaDataTags.UnixTime);

    % Unix time is an absolute (UTC) instant; express it in the recording's
    % zone when one is recorded, else keep it in UTC
    fNIR.t0 = datetime(unixTime, 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');

    if isfield(metaDataTags, 'MeasurementTimeZone') && ~isempty(metaDataTags.MeasurementTimeZone)
        try
            fNIR.t0.TimeZone = metaDataTags.MeasurementTimeZone;
        catch
            warning('pf2:importSNIRF:badTimeZone', ...
                'Unrecognized MeasurementTimeZone ''%s''; t0 is kept in UTC.', ...
                char(metaDataTags.MeasurementTimeZone));
        end
    end
elseif isfield(metaDataTags, 'MeasurementTime') && isfield(metaDataTags, 'MeasurementDate')
    % ISO date + time, with an optional UTC offset (Z or +hh:mm). With an
    % offset the instant is absolute; without one it is the device's
    % wall-clock time and stays zone-less unless MeasurementTimeZone names
    % the zone. The zone is never taken from this machine.
    dateTimeStr = [strtrim(char(metaDataTags.MeasurementDate)) 'T' strtrim(char(metaDataTags.MeasurementTime))];
    tz = '';
    if isfield(metaDataTags, 'MeasurementTimeZone') && ~isempty(metaDataTags.MeasurementTimeZone)
        tz = char(metaDataTags.MeasurementTimeZone);
    end
    fmts = {'yyyy-MM-dd''T''HH:mm:ss.SSSSSSXXX', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX', 'yyyy-MM-dd''T''HH:mm:ssXXX', ...
            'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx', 'yyyy-MM-dd''T''HH:mm:ss.SSSxxx', 'yyyy-MM-dd''T''HH:mm:ssxxx'};
    for k = 1:numel(fmts)
        try
            fNIR.t0 = datetime(dateTimeStr, 'InputFormat', fmts{k}, 'TimeZone', 'UTC');
            break;
        catch
        end
    end
    if ~isfield(fNIR, 't0')
        fmts = {'yyyy-MM-dd''T''HH:mm:ss.SSSSSS', 'yyyy-MM-dd''T''HH:mm:ss.SSS', 'yyyy-MM-dd''T''HH:mm:ss'};
        for k = 1:numel(fmts)
            try
                fNIR.t0 = datetime(dateTimeStr, 'InputFormat', fmts{k});
                break;
            catch
            end
        end
    end
    if ~isfield(fNIR, 't0')
        warning('Failed to parse date/time information');
    elseif ~isempty(tz)
        try
            fNIR.t0.TimeZone = tz;   % converts a zoned t0; labels a zone-less one
        catch
            warning('pf2:importSNIRF:badTimeZone', ...
                'Unrecognized MeasurementTimeZone ''%s''; ignored.', tz);
        end
    end
end

% Set up device info for fNIR structure
device.cfg = pf2_base.external.INI();
device.Info.CfgName = 'generated SNIRF file';

% Set device manufacturer and model info if available
if isfield(metaDataTags, 'Model')
    device.Info.Name = metaDataTags.Model;
else
    device.Info.Name = 'Unknown Model';
end

if isfield(metaDataTags, 'ManufacturerName')
    device.Info.Manufacturer = metaDataTags.ManufacturerName;
else
    device.Info.Manufacturer = 'Unknown Manufacturer';
end 

% Set device sampling info
device.Info.DefaultSamplingRate = fNIR.fs;
device.Info.MaxSamplingRate = fNIR.fs;
device.Info.NumberProbes = 1;
device.Info.RawMax = nanmax(nanmax(fNIR.raw));
device.Info.RawMin = nanmin(nanmin(fNIR.raw));
device.Info.NumberChannels = 0;

% Process probe information
for p = 1:1 % Just one probe for now
    curProbeIdx = 1;
    device.Probe{p} = [];
    device.Probe{p}.TableSD = table();
    device.Probe{p}.TableCh = table(); % Map for raw probe data, 1 row per measurementList
    
    device.Probe{p}.TableCh.ColNumber = (1:height(measurementList))';
    numCh = height(measurementList);
    
    % Get unique optode pairs
    [~, firstOpt, uOpt] = unique(measurementList(:, {'sourceIndex','detectorIndex' }), 'rows',  'stable');
    device.Probe{p}.TableCh.OptodeNumber = uOpt;
    
    % Handle time signals
    timeSignalIdx = find(strcmp(measurementList.dataTypeLabel, 'time-signal'));
    if ~isempty(timeSignalIdx)
        firstOpt(firstOpt == timeSignalIdx) = []; % Remove time signal from "first opt" argument
        device.Probe{p}.TableCh.OptodeNumber(timeSignalIdx) = 0;
    end
    
    % Mark time and marker channels
    device.Probe{p}.TableCh.isTime = device.Probe{p}.TableCh.OptodeNumber == 0;
    device.Probe{p}.TableCh.isMarker = device.Probe{p}.TableCh.OptodeNumber < 0 | isnan(device.Probe{p}.TableCh.OptodeNumber);
    device.Probe{p}.TableCh.OptodeNumber(device.Probe{p}.TableCh.OptodeNumber < 1) = nan;
    device.Probe{p}.TableCh.isCh=device.Probe{p}.TableCh.OptodeNumber > 0;
    
    numOpt = length(firstOpt);
    
    % Reindex optodes for consistent ordering
    opt_list = device.Probe{p}.TableCh.OptodeNumber;
    reindexed_lookup = nan(numOpt, 2);
    reindexed_list = nan(size(opt_list));
    next_index = 1;
    
    for i = 1:length(opt_list)
        if isnan(opt_list(i))
            continue;
        end
        % Find if this optode number was already seen
        matchIdx = find(reindexed_lookup(:, 2) == opt_list(i), 1);
        if ~isempty(matchIdx)
            % Use the previously assigned index for this optode number
            reindexed_list(i) = reindexed_lookup(matchIdx, 1);
        else
            % Assign new sequential index
            reindexed_lookup(next_index, 1) = next_index;
            reindexed_lookup(next_index, 2) = opt_list(i);

            reindexed_list(i) = next_index;
            next_index = next_index + 1;
        end
    end
    
    device.Probe{p}.TableCh.OptodeNumber = reindexed_list;
    
    % Handle wavelength information
    validWVindex = ~isnan(measurementList.('wavelengthIndex')) & measurementList.('wavelengthIndex')>0;
    device.Probe{p}.TableCh.Wavelength(:) = nan;
    
    % Set wavelengths for valid indices
    if ~isempty(validWVindex) && any(validWVindex) && isfield(probeInfo, 'wavelengths')
        device.Probe{p}.TableCh.Wavelength(validWVindex) = probeInfo.wavelengths(measurementList{validWVindex, 'wavelengthIndex'})';
    end
    
    % Mark dark channels
    device.Probe{p}.TableCh.isDark = (isnan(device.Probe{p}.TableCh.Wavelength) | device.Probe{p}.TableCh.Wavelength == 0);
    
    % Explicitly mark dark channels based on dataTypeLabel
    darkLabelIdx = find(contains(measurementList.dataTypeLabel, 'dark'));
    if ~isempty(darkLabelIdx)
        device.Probe{p}.TableCh.isDark(darkLabelIdx) = true;
    end
    
    % Set source and detector indices
    device.Probe{p}.TableCh.SourceIndex(:) = measurementList.('sourceIndex');
    device.Probe{p}.TableCh.DetectorIndex(:) = measurementList.('detectorIndex');
    
    % Get unique sources and detectors
    uSrc = unique(device.Probe{p}.TableCh.SourceIndex);
    uDet = unique(device.Probe{p}.TableCh.DetectorIndex);
    
    numSrc = length(uSrc);
    numDet = length(uDet);
    
    % Create tables for source and detector positions
    device.Probe{p}.SrcPos = table();
    device.Probe{p}.DetPos = table();
    
    % Get source and detector positions
    srcXYZ = probeInfo.sourcePos3D;
    if isfield(probeInfo, 'sourcePos2D')
        srcXYZ_2d = probeInfo.sourcePos2D;
    else
        srcXYZ_2d = srcXYZ(:, 1:2);  % Project to XY plane
    end

    detXYZ = probeInfo.detectorPos3D;
    if isfield(probeInfo, 'detectorPos2D')
        detXYZ_2d = probeInfo.detectorPos2D;
    else
        detXYZ_2d = detXYZ(:, 1:2);  % Project to XY plane
    end
    
    % Store positions
    device.Probe{p}.SrcPosX = srcXYZ(:, 1);
    device.Probe{p}.SrcPosY = srcXYZ(:, 2);
    device.Probe{p}.SrcPosZ = srcXYZ(:, 3);
    device.Probe{p}.DetPosX = detXYZ(:, 1);
    device.Probe{p}.DetPosY = detXYZ(:, 2);
    device.Probe{p}.DetPosZ = detXYZ(:, 3);
    
    device.Probe{p}.SrcPos3D = srcXYZ;
    device.Probe{p}.DetPos3D = detXYZ;
    
    % Store 2D positions
    device.Probe{p}.SrcPos.x_2d = srcXYZ_2d(:, 1);
    device.Probe{p}.SrcPos.y_2d = srcXYZ_2d(:, 2);
    device.Probe{p}.SrcPos.z_2d = srcXYZ_2d(:, 1) * 0;
    device.Probe{p}.SrcPos.x = device.Probe{p}.SrcPosX(:);
    device.Probe{p}.SrcPos.y = device.Probe{p}.SrcPosY(:);
    device.Probe{p}.SrcPos.z = device.Probe{p}.SrcPosZ(:);
    
    device.Probe{p}.DetPos.x_2d = detXYZ_2d(:, 1);
    device.Probe{p}.DetPos.y_2d = detXYZ_2d(:, 2);
    device.Probe{p}.DetPos.z_2d = detXYZ_2d(:, 1) * 0;
    device.Probe{p}.DetPos.x = device.Probe{p}.DetPosX(:);
    device.Probe{p}.DetPos.y = device.Probe{p}.DetPosY(:);
    device.Probe{p}.DetPos.z = device.Probe{p}.DetPosZ(:);
    
    % Initialize channel labels
    device.Probe{p}.TableCh.Label(:) = "";
    
    % Set labels based on channel type
    for ch = 1:numCh
        if device.Probe{p}.TableCh.isTime(ch)
            device.Probe{p}.TableCh.Label(ch) = "Time"; 
        elseif device.Probe{p}.TableCh.isMarker(ch)
            device.Probe{p}.TableCh.Label(ch) = "Mrk";
        elseif device.Probe{p}.TableCh.isDark(ch)
            opt = device.Probe{p}.TableCh.OptodeNumber(ch);
            device.Probe{p}.TableCh.Label(ch) = sprintf('Opt%i_dark', opt);
        else
            wv = device.Probe{p}.TableCh.Wavelength(ch);
            opt = device.Probe{p}.TableCh.OptodeNumber(ch);
            device.Probe{p}.TableCh.Label(ch) = sprintf('Opt%i_wv%.1f', opt, wv);
        end
    end
    
    % Set up optode table
    device.Probe{p}.TableOpt = table();
    device.Probe{p}.TableOpt.OptodeNum(:) = (1:numOpt)';
    
    % Set source and detector indices for each optode
    device.Probe{p}.dI = measurementList.('detectorIndex');
    device.Probe{p}.sI = measurementList.('sourceIndex');
    
    device.Probe{p}.TableOpt.SrcIdx = measurementList{firstOpt, 'sourceIndex'};
    device.Probe{p}.TableOpt.DetIdx = measurementList{firstOpt, 'detectorIndex'};
    
    % Get unique source-detector pairs
    SDpairs = [device.Probe{p}.sI, device.Probe{p}.dI];
    SDpairs = SDpairs(sum(SDpairs,2)>0,:);
    [uPairs, ~, uPairIdx] = unique(SDpairs, 'rows', 'stable');
    validRows = ~isnan(sum(uPairs, 2));
    
    uPairs = uPairs(validRows, :);
    
    % Calculate optode positions
    for opt = 1:numOpt
        sIdx = device.Probe{p}.TableOpt.SrcIdx(opt);
        dIdx = device.Probe{p}.TableOpt.DetIdx(opt);
        
        if isnan(sIdx) || isnan(dIdx)
            srcPosX(opt) = nan;
            srcPosY(opt) = nan;
            srcPosZ(opt) = nan;
            detPosX(opt) = nan;
            detPosY(opt) = nan;
            detPosZ(opt) = nan;
            srcPos3D(opt, :) = nan(1, 3);
            detPos3D(opt, :) = nan(1, 3);
        else
            srcPosX(opt) = device.Probe{p}.SrcPosX(sIdx);
            srcPosY(opt) = device.Probe{p}.SrcPosY(sIdx);
            srcPosZ(opt) = device.Probe{p}.SrcPosZ(sIdx);
            detPosX(opt) = device.Probe{p}.DetPosX(dIdx);
            detPosY(opt) = device.Probe{p}.DetPosY(dIdx);
            detPosZ(opt) = device.Probe{p}.DetPosZ(dIdx);
            srcPos3D(opt, :) = device.Probe{p}.SrcPos3D(sIdx, :);
            detPos3D(opt, :) = device.Probe{p}.DetPos3D(dIdx, :);
        end
    end
    
    device.Probe{p}.SrcPosX = srcPosX';
    device.Probe{p}.SrcPosY = srcPosY';
    device.Probe{p}.SrcPosZ = srcPosZ';
    device.Probe{p}.DetPosX = detPosX';
    device.Probe{p}.DetPosY = detPosY';
    device.Probe{p}.DetPosZ = detPosZ';
    
    % Calculate optode midpoint positions
    device.Probe{p}.OptPosX = mean([device.Probe{p}.SrcPosX(:, 1), device.Probe{p}.DetPosX(:, 1)], 2);
    device.Probe{p}.OptPosY = mean([device.Probe{p}.SrcPosY(:, 1), device.Probe{p}.DetPosY(:, 1)], 2);
    device.Probe{p}.OptPosZ = mean([device.Probe{p}.SrcPosZ(:, 1), device.Probe{p}.DetPosZ(:, 1)], 2);
    device.Probe{p}.NumOptodes = numOpt;
    
    % Canonical optode positions live in TableOpt; the OptPos view is derived
    % from it via pf2_base.syncOptodeCoords (single source of truth).
    device.Probe{p}.TableOpt.Pos2D_x = device.Probe{p}.OptPosX(:);
    device.Probe{p}.TableOpt.Pos2D_y = device.Probe{p}.OptPosY(:);
    device.Probe{p}.TableOpt.Pos2D_z = device.Probe{p}.OptPosZ(:);
    device.Probe{p}.TableOpt.Pos3D_x = device.Probe{p}.OptPosX(:);
    device.Probe{p}.TableOpt.Pos3D_y = device.Probe{p}.OptPosY(:);
    device.Probe{p}.TableOpt.Pos3D_z = device.Probe{p}.OptPosZ(:);

    device.Probe{p}.OptPos = table();
    device.Probe{p} = pf2_base.syncOptodeCoords(device.Probe{p});
    
    device.Probe{p}.DetPos3D = detPos3D;
    device.Probe{p}.SrcPos3D = srcPos3D;
    
    % Set up source-detector table
    device.Probe{p}.TableSD = table();
    
    Type_temp = [ones([height(device.Probe{p}.SrcPos), 1]); ones([height(device.Probe{p}.DetPos), 1]) * 2];
    typeStr_temp = {'Src', 'Det'};
    
    catType_temp = categorical(typeStr_temp(Type_temp(:)), typeStr_temp);
    device.Probe{p}.TableSD.Type = catType_temp(:);
    
    device.Probe{p}.TableSD.Index = [(1:height(device.Probe{p}.SrcPos))'; (1:height(device.Probe{p}.DetPos))'];
    
    for sd = 1:height(device.Probe{p}.TableSD)
        typeLabel = sprintf('%s', device.Probe{p}.TableSD.Type(sd));
        device.Probe{p}.TableSD.Label{sd} = sprintf('%s%i', typeLabel(1), device.Probe{p}.TableSD.Index(sd));
    end
    
    % Set source-detector positions
    device.Probe{p}.TableSD.Pos2D_x = [device.Probe{p}.SrcPos.x_2d(:); device.Probe{p}.DetPos.x_2d(:)];
    device.Probe{p}.TableSD.Pos2D_y = [device.Probe{p}.SrcPos.y_2d(:); device.Probe{p}.DetPos.y_2d(:)];
    device.Probe{p}.TableSD.Pos2D_z = [device.Probe{p}.SrcPos.z_2d(:); device.Probe{p}.DetPos.z_2d(:)];
    
    device.Probe{p}.TableSD.Pos3D_x = [device.Probe{p}.SrcPos.x(:); device.Probe{p}.DetPos.x(:)];
    device.Probe{p}.TableSD.Pos3D_y = [device.Probe{p}.SrcPos.y(:); device.Probe{p}.DetPos.y(:)];
    device.Probe{p}.TableSD.Pos3D_z = [device.Probe{p}.SrcPos.z(:); device.Probe{p}.DetPos.z(:)];
    
    device.Probe{p}.OptPos3D = (srcPos3D + detPos3D) / 2;
    
    % Calculate source-detector distances. Optode positions are kept in mm
    % internally (to match the declared CoordinateUnits and round-trip BIDS
    % export), but TableOpt.SD follows the toolbox-wide convention of cm so
    % the modified Beer-Lambert law (pf2_base.fnirs.bvoxy, whose extinction
    % coefficients are in 1/(cm*M)) and short-separation detection match every
    % other import path (loadDeviceCfg, importNIRX, importOxy3 all store cm).
    device.Probe{p}.SD = sqrt((device.Probe{p}.SrcPosX - device.Probe{p}.DetPosX).^2 + ...
        (device.Probe{p}.SrcPosY - device.Probe{p}.DetPosY).^2 + (device.Probe{p}.SrcPosZ - device.Probe{p}.DetPosZ).^2)' / 10;  % mm -> cm
    device.Probe{p}.IsShortSeparation = device.Probe{p}.SD < 2;  % cm threshold (~20 mm)
    device.Probe{p}.NumShortSeparation = sum(device.Probe{p}.IsShortSeparation);
    
    device.Probe{p}.TableOpt.SD = device.Probe{p}.SD(:);
    device.Probe{p}.TableOpt.IsShortSeparation = device.Probe{p}.IsShortSeparation(:);
    
    % Store source/detector labels from SNIRF if available
    if isfield(probeInfo, 'sourceLabels')
        device.Probe{p}.SourceLabels = probeInfo.sourceLabels;
    end
    if isfield(probeInfo, 'detectorLabels')
        device.Probe{p}.DetectorLabels = probeInfo.detectorLabels;
    end

    % Build per-optode S_D channel labels (e.g., "S1_D11")
    optLabels = cell(numOpt, 1);
    for opt = 1:numOpt
        sIdx = device.Probe{p}.TableOpt.SrcIdx(opt);
        dIdx = device.Probe{p}.TableOpt.DetIdx(opt);
        if isfield(probeInfo, 'sourceLabels') && sIdx <= length(probeInfo.sourceLabels) && ...
           isfield(probeInfo, 'detectorLabels') && dIdx <= length(probeInfo.detectorLabels)
            sLabel = probeInfo.sourceLabels{sIdx};
            dLabel = probeInfo.detectorLabels{dIdx};
            % Normalize to "S#_D#" format
            if ~startsWith(sLabel, 'S'), sLabel = ['S' sLabel]; end
            if ~startsWith(dLabel, 'D'), dLabel = ['D' dLabel]; end
            optLabels{opt} = [sLabel '_' dLabel];
        else
            optLabels{opt} = sprintf('S%d_D%d', sIdx, dIdx);
        end
    end
    device.Probe{p}.TableOpt.ChannelLabel = optLabels;

    % Store channel mapping info
    device.Probe{p}.probeNum = 1;
    device.Probe{p}.wvI = reshape(measurementList.('wavelengthIndex'), [1, height(measurementList)]);
    device.Probe{p}.ChannelNumbers = uPairIdx';
    uniqueChannels = unique(device.Probe{p}.ChannelNumbers);
    device.Probe{p}.ChannelList = uniqueChannels(uniqueChannels > 0);
    device.Probe{p}.Wavelength = probeInfo.wavelengths(:)';
    device.Info.NumberChannels = device.Info.NumberChannels + length(device.Probe{p}.ChannelList);

    % Map wavelengths to channels (variable width per optode)
    for c = 1:length(device.Probe{p}.ChannelList)
        chIdxMatch = find(device.Probe{p}.ChannelNumbers == device.Probe{p}.ChannelList(c));
        device.Probe{p}.TableOpt.Ch(c, 1:length(chIdxMatch)) = chIdxMatch;
        wvIdxToMatch = device.Probe{p}.wvI(chIdxMatch);
        if ~any(isnan(wvIdxToMatch))
            device.Probe{p}.TableOpt.wv(c, 1:length(chIdxMatch)) = device.Probe{p}.Wavelength(wvIdxToMatch);
        end
        device.Probe{p}.TableOpt.Label{c} = sprintf('Ch%i', device.Probe{p}.ChannelList(c));
    end
    
    % Generate probe layout
    if buildProbeLayout
        if isfield(device.Probe{p}, 'OptPosX') && isfield(device.Probe{p}, 'OptPosY')
            if includeSSchannels
                try
                    device.Probe{p}.OptLayout2D_ss = pf2_base.fitProbe2D(device.Probe{p}.OptPosX, device.Probe{p}.OptPosY, device.Probe{p}.OptPosZ);
                catch
                    device.Probe{p}.OptLayout2D_ss = setUpFalse2D(device.Probe{p}.NumOptodes);
                end
            end

            try
                device.Probe{p}.OptLayout2D = pf2_base.fitProbe2D(device.Probe{p}.OptPosX(~device.Probe{p}.IsShortSeparation), ...
                    device.Probe{p}.OptPosY(~device.Probe{p}.IsShortSeparation), ...
                    device.Probe{p}.OptPosZ(~device.Probe{p}.IsShortSeparation));
            catch
                nLong = sum(~device.Probe{p}.IsShortSeparation);
                device.Probe{p}.OptLayout2D = setUpFalse2D(nLong);
            end
        else
            warning('buildProbeLayout option selected, but not enough information to generate Optode locations');
            device.Probe{p}.OptLayout2D = setUpFalse2D(device.Probe{p}.NumOptodes);
        end
    else
        device.Probe{p}.OptLayout2D = setUpFalse2D(device.Probe{p}.NumOptodes);
    end
    
    % Set subplot layout
    device.Probe{p}.OptPos.subplot_layout(:) = cell(size(device.Probe{p}.OptPos.z));
    device.Probe{p}.OptPos.subplot_layout(~device.Probe{p}.IsShortSeparation) = device.Probe{p}.OptLayout2D(:);
    
    if includeSSchannels
        device.Probe{p}.OptPos.subplot_layout_ss = device.Probe{p}.OptLayout2D_ss(:);
    else
        device.Probe{p}.OptPos.subplot_layout_ss = device.Probe{p}.OptPos.subplot_layout;
    end
end

% Collect coordinate system information for Device object
coordSys = '';
coordSysDesc = '';
coordUnits = '';
landmarks = [];

% Check SNIRF probe for coordinate system info
if isfield(probeInfo, 'coordinateSystem')
    coordSys = probeInfo.coordinateSystem;
end
% pf2 writes a non-BIDS device tag (e.g. 'MNI') as probe 'Other' plus a
% CoordinateSystem metadata tag; restore the device tag
if strcmpi(strtrim(char(string(coordSys))), 'Other') && isfield(metaDataTags, 'CoordinateSystem') ...
        && ~isempty(metaDataTags.CoordinateSystem)
    coordSys = char(metaDataTags.CoordinateSystem);
end

if isempty(coordSys)
    % Try to read from BIDS sidecar (coordsystem.json)
    coordSysInfo = loadBIDScoordSystem(filepath);
    if ~isempty(coordSysInfo)
        coordSys = coordSysInfo.system;
        coordSysDesc = coordSysInfo.description;
        coordUnits = coordSysInfo.units;
    else
        coordSys = 'Unknown';
    end
end

if isfield(probeInfo, 'coordinateSystemDescription')
    coordSysDesc = probeInfo.coordinateSystemDescription;
end

% Collect landmarks (fiducials, 10-20 electrodes, head points) for registration
% Note: scaling has already been applied to probeInfo.landmarkPos3D above
if isfield(probeInfo, 'landmarkPos3D') && isfield(probeInfo, 'landmarkLabels')
    landmarkPos = probeInfo.landmarkPos3D;
    landmarkLabels = probeInfo.landmarkLabels;

    % Create landmarks table. Labels may load as a char matrix (fixed-width
    % strings, as NIRx writes them), a string array or a cellstr.
    nLandmarks = size(landmarkPos, 1);
    if ischar(landmarkLabels)
        if size(landmarkLabels, 1) ~= nLandmarks && size(landmarkLabels, 2) == nLandmarks
            landmarkLabels = landmarkLabels';
        end
        landmarkLabels = cellstr(landmarkLabels);
    elseif isstring(landmarkLabels)
        landmarkLabels = cellstr(landmarkLabels);
    end
    if iscell(landmarkLabels)
        landmarkLabels = strtrim(landmarkLabels(:));
    end
    if nLandmarks == numel(landmarkLabels)
        landmarks = table();
        landmarks.Label = landmarkLabels(:);
        landmarks.X = landmarkPos(:, 1);
        landmarks.Y = landmarkPos(:, 2);
        landmarks.Z = landmarkPos(:, 3);

        % Classify landmark types
        landmarkType = repmat("electrode", nLandmarks, 1);
        fiducialLabels = {'LPA', 'RPA', 'NASION', 'NAS', 'Nz', 'Iz', 'INION'};
        for li = 1:nLandmarks
            lbl = landmarks.Label{li};
            if any(strcmpi(lbl, fiducialLabels))
                landmarkType(li) = "fiducial";
            elseif startsWith(lbl, 'HP_') || startsWith(lbl, 'HP')
                landmarkType(li) = "headpoint";
            end
        end
        landmarks.Type = categorical(landmarkType);
    end
end

% Import auxiliary data if available
if isfield(nirs, 'aux') && ~isempty(nirs.aux)
    fNIR.Aux = struct();
    
    for i = 1:length(nirs.aux)
        auxItem = nirs.aux(i);
        
        if ~isfield(auxItem, 'name') || ~isfield(auxItem, 'dataTimeSeries')
            continue;
        end
        
        % Create a valid field name
        fieldName = regexprep(auxItem.name, '[^a-zA-Z0-9_]', '_');
        
        % Create auxiliary data structure
        fNIR.Aux.(fieldName) = struct();
        fNIR.Aux.(fieldName).data = auxItem.dataTimeSeries;
        
        % Add time if available
        if isfield(auxItem, 'time')
            fNIR.Aux.(fieldName).time = auxItem.time;
        else
            fNIR.Aux.(fieldName).time = fNIR.time;
        end
        
        % Add unit if available
        if isfield(auxItem, 'dataUnit')
            fNIR.Aux.(fieldName).unit = auxItem.dataUnit;
        end
    end
end

% Set channel quality mask (one per optode pair, all good by default)
fNIR.fchMask = ones(1, device.Info.NumberChannels);


% Save probe info
if isfield(fNIR, 'probeinfo')
    global setF
    device.cfg.add('Info', device.Info);
    for i = 1:length(device.Probe)
        device.cfg.add(sprintf('Probe%i', i), device.Probe{i});
    end

    setF.device = device;
else
    fNIR.probeinfo = device;
end

% Attach Device object for self-describing data
deviceArgs = {};
if ~isempty(coordSys)
    deviceArgs = [deviceArgs, {'CoordinateSystem', coordSys}];
end
if ~isempty(coordSysDesc)
    deviceArgs = [deviceArgs, {'CoordinateSystemDescription', coordSysDesc}];
end
if ~isempty(coordUnits)
    deviceArgs = [deviceArgs, {'CoordinateUnits', coordUnits}];
end
if ~isempty(landmarks)
    deviceArgs = [deviceArgs, {'Landmarks', landmarks}];
end
fNIR.device = pf2.Device.fromProbeInfo(device, '', deviceArgs{:});


% Load existing channel mask if available and not checking
if ~channelCheck
    ch_mask_file = sprintf('%s_CH.mat', filepath);
    
    try
        fmask = load(ch_mask_file, 'fmask');
        fmask = fmask.fmask;
        fprintf('%i Channels marked bad\n', sum(fmask < 1));
    catch
        fprintf('No channel rejection present\n');
        fmask = [];
    end
else
    fmask = [];
end

% Run channel quality check if requested and a GUI can be shown; otherwise
% keep a saved mask or the all-good default (set above) and never block.
if channelCheck && pf2_base.allowChannelCheckGUI()
    if channelCheckVersion == 2
        app = pf2.qc.ChannelCheck(fNIR, 'CalledFromImport', true, 'SkipConfirmation', true);
        if isvalid(app), fNIR = app.OutputData; delete(app); end
    else
        fNIR = probeCheckGUI(fNIR, filepath, forceChannelCheck);
    end
elseif channelCheck
    % Requested but the GUI is unavailable/suppressed (headless, under test,
    % or disabled): honor a saved sidecar mask if present, otherwise the
    % all-good default already in fNIR.fchMask.
    fNIR = pf2_base.loadExistingMaskOrCheck(fNIR, filepath, channelCheckVersion);
else
    if ~isempty(fmask)
        fNIR.fchMask = fmask;
    end
end

end

function T = stimToTable(curStim)
    % STIMTOTABLE Convert one SNIRF stim entry into a canonical marker table.
    %
    % Standard SNIRF stim data columns are [startTime, duration, value, ...].
    % When dataLabels are present they are used to map columns to the
    % canonical variables (Time, Code, Duration) and to NAME any extra
    % columns (e.g. amplitude, GameScore), so they survive a round-trip.
    % Without labels, the standard positional order is assumed -- EXCEPT for
    % a 2-column block, which is treated as legacy fNIR [time, code] (column 2
    % is the marker code, not duration), since that is what fNIR .nir/.mrk
    % markers carry and losing the code is far worse than losing a duration.

    T = [];
    d = curStim.data;
    if isempty(d) || size(d, 2) < 2
        return;
    end
    nCol = size(d, 2);

    % Resolve labels (lowercased) if available and well-sized
    labels = {};
    if isfield(curStim, 'dataLabels') && ~isempty(curStim.dataLabels)
        lab = cellstr(string(curStim.dataLabels));
        if numel(lab) >= nCol
            labels = lab(1:nCol);
        end
    end

    % Column indices for the canonical fields (default SNIRF positions)
    ti = 1; di = 2; vi = 3;
    if ~isempty(labels)
        llab = lower(labels);
        a = find(ismember(llab, {'starttime', 'time', 'onset'}), 1);
        b = find(ismember(llab, {'duration', 'length'}), 1);
        c = find(ismember(llab, {'value', 'code', 'type', 'id', 'marker'}), 1);
        if ~isempty(a); ti = a; end
        if ~isempty(b); di = b; end
        if ~isempty(c); vi = c; end
    elseif nCol == 2
        % Legacy fNIR [time, code]: column 2 is the code, no duration column.
        di = 0; vi = 2;
        warning('pf2:importSNIRF:twoColumnStim', ...
            ['2-column SNIRF stim block found; treating column 2 as the marker ', ...
             'code (legacy [time, code]) rather than duration.']);
    end

    nRow = size(d, 1);
    Time     = d(:, ti);
    Duration = zeros(nRow, 1);
    if di >= 1 && di <= nCol; Duration = d(:, di); end
    Code     = zeros(nRow, 1);
    if vi >= 1 && vi <= nCol; Code = d(:, vi); end

    T = table(Time, Code, Duration, 'VariableNames', {'Time', 'Code', 'Duration'});

    % Carry remaining columns as named extras
    coreCols = [ti, di, vi];
    for j = 1:nCol
        if ismember(j, coreCols); continue; end
        if ~isempty(labels)
            nm = matlab.lang.makeValidName(labels{j});
        else
            nm = sprintf('Data%d', j);
        end
        if ismember(nm, T.Properties.VariableNames)
            nm = matlab.lang.makeUniqueStrings([nm '_x'], T.Properties.VariableNames);
        end
        T.(nm) = d(:, j);
    end
end

function opt_2d_coords = setUpFalse2D(numCh)
    % Create a fallback 2D layout when real coordinates aren't available
    opt_2d_coords = cell(1, numCh);
    
    for i = 1:numCh
        x1 = i - 1;
        x2 = 1;
        y1 = 0;
        y2 = 0.9;
        x2 = x2 / numCh;
        x1 = x1 / numCh;
        
        opt_2d_coords{i} = [x1, y1, x2, y2];
    end
end

function outTable = struct2table(structObj)
    % Convert structure array to table
    fieldsInStruct = fieldnames(structObj(1));
   
    outTable = table();
    for n = 1:length(structObj)
        newTable = table();
        for f = 1:length(fieldsInStruct)
            % Handle various data types properly
            if isfield(structObj(n), fieldsInStruct{f})
                newTable.(fieldsInStruct{f}) = structObj(n).(fieldsInStruct{f});
                
                % Convert character arrays to cell strings
                if ischar(newTable.(fieldsInStruct{f})) || isstring(newTable.(fieldsInStruct{f}))
                    newTable.(fieldsInStruct{f}) = cellstr(newTable.(fieldsInStruct{f}));
                end
            else
                % Handle missing fields with empty values
                newTable.(fieldsInStruct{f}) = [];
            end
        end
        outTable = [outTable; newTable];
    end
end

function outStruct = stripStruct(structObj)
    % Clean up metadata structure by removing null characters and whitespace
    fieldsInStruct = fieldnames(structObj);

    outStruct = structObj;

    for f = 1:length(fieldsInStruct)
        temp = structObj.(fieldsInStruct{f});

        % Only process character/string data
        if ischar(temp) || isstring(temp)
            % Remove null characters and trim whitespace
            outStruct.(fieldsInStruct{f}) = strtrim(strrep(reshape(temp, [1, length(temp)]), char(0), ''));
        end
    end
end

function [markers, eventTypes] = loadBIDSevents(snirfPath)
% LOADBIDSEVENTS Load markers and event type mapping from BIDS events.tsv
%
% Looks for a companion _events.tsv file alongside the SNIRF file
% following BIDS naming conventions. Parses onset, duration, trial_type,
% and value columns into the pf2 marker format [time, value, duration, amplitude].
% When both trial_type and value columns exist, builds a mapping between them.
%
% Inputs:
%   snirfPath - Full path to the SNIRF file
%
% Outputs:
%   markers    - Marker array [M x 4] or empty []
%   eventTypes - Cell array {code, 'Label'; ...} mapping value → trial_type, or {}

markers = [];
eventTypes = {};

[parentDir, baseName, ~] = fileparts(snirfPath);

% BIDS convention: replace _nirs.snirf with _events.tsv
eventsName = regexprep(baseName, '_nirs$', '_events.tsv');
eventsFile = fullfile(parentDir, eventsName);

if ~isfile(eventsFile)
    % Try without the _nirs suffix
    eventsFile = fullfile(parentDir, [baseName '_events.tsv']);
end

if ~isfile(eventsFile)
    return;
end

try
    eventsTable = readtable(eventsFile, 'FileType', 'text', 'Delimiter', '\t');

    colNames = eventsTable.Properties.VariableNames;

    if ~ismember('onset', colNames)
        return;
    end

    onsets = eventsTable.onset;
    nEvents = length(onsets);
    durations = zeros(nEvents, 1);
    values = ones(nEvents, 1);
    hasValue = false;

    % Duration column
    if ismember('duration', colNames)
        durations = eventsTable.duration;
    end

    % Value column (numeric codes)
    if ismember('value', colNames)
        if isnumeric(eventsTable.value)
            values = eventsTable.value;
            hasValue = true;
        end
    end

    % If no numeric values, map trial_type strings to sequential codes
    if ~hasValue && ismember('trial_type', colNames)
        types = eventsTable.trial_type;
        if iscell(types) || isstring(types)
            [uniqueTypes, ~, typeIdx] = unique(types, 'stable');
            values = typeIdx;
            fprintf('BIDS events: mapped %d trial types from %s\n', ...
                length(uniqueTypes), eventsFile);
            for t = 1:length(uniqueTypes)
                fprintf('  %s = %d\n', char(uniqueTypes(t)), t);
            end
        end
    end

    % Build trial_type → value mapping when trial_type column exists
    if ismember('trial_type', colNames)
        types = eventsTable.trial_type;
        if iscell(types) || isstring(types)
            [uniqueTypes, ~, ~] = unique(types, 'stable');
            for t = 1:numel(uniqueTypes)
                typeName = char(uniqueTypes(t));
                mask = strcmp(types, typeName);
                if hasValue
                    code = eventsTable.value(find(mask, 1));
                else
                    code = t;
                end
                eventTypes(end+1, :) = {code, typeName}; %#ok<AGROW>
            end
        end
    end

    markers = pf2_base.normalizeMarkers([onsets, values, durations, ones(nEvents, 1)]);

catch e
    warning('pf2:import:bidsEventsFailed', ...
        'Failed to load BIDS events from %s: %s', eventsFile, e.message);
end

end

function coordSysInfo = loadBIDScoordSystem(snirfPath)
% LOADBIDSCOORDSYSTEM Load coordinate system info from BIDS coordsystem.json
%
% Looks for a companion _coordsystem.json file alongside the SNIRF file
% following BIDS naming conventions. Parses NIRSCoordinateSystem,
% NIRSCoordinateSystemDescription, and NIRSCoordinateUnits.
%
% Inputs:
%   snirfPath - Full path to the SNIRF file
%
% Outputs:
%   coordSysInfo - Struct with fields: system, description, units
%                  Empty [] if file not found or parse error

coordSysInfo = [];

[parentDir, baseName, ~] = fileparts(snirfPath);

% BIDS convention: replace _nirs.snirf or _task-XXX_nirs.snirf with _coordsystem.json
% First try: sub-XX_ses-XX_coordsystem.json (session-level)
coordName = regexprep(baseName, '_task-[^_]+_nirs$', '_coordsystem.json');
coordFile = fullfile(parentDir, coordName);

if ~isfile(coordFile)
    % Try with subject-session prefix only
    tokens = regexp(baseName, '^(sub-[^_]+(?:_ses-[^_]+)?)_', 'tokens');
    if ~isempty(tokens)
        coordFile = fullfile(parentDir, [tokens{1}{1} '_coordsystem.json']);
    end
end

if ~isfile(coordFile)
    return;
end

try
    coordJson = jsondecode(fileread(coordFile));

    coordSysInfo = struct();
    coordSysInfo.system = '';
    coordSysInfo.description = '';
    coordSysInfo.units = 'mm';

    if isfield(coordJson, 'NIRSCoordinateSystem')
        coordSysInfo.system = coordJson.NIRSCoordinateSystem;
    end
    if isfield(coordJson, 'NIRSCoordinateSystemDescription')
        coordSysInfo.description = coordJson.NIRSCoordinateSystemDescription;
    end
    if isfield(coordJson, 'NIRSCoordinateUnits')
        coordSysInfo.units = coordJson.NIRSCoordinateUnits;
    end

catch e
    warning('pf2:import:bidsCoordFailed', ...
        'Failed to load BIDS coordsystem from %s: %s', coordFile, e.message);
    coordSysInfo = [];
end

end
