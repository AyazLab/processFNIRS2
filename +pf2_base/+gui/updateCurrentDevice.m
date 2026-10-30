function result = updateCurrentDevice(device, dataStruct)
% UPDATECURRENTDEVICE Build merged probe tables and resolve time vector
%
% Shared device/table setup used by both GUI and headless processing paths.
% Merges probe tables across probes, finds the time column index, and
% resolves time vector and sampling rate from the data.
%
% Syntax:
%   result = pf2_base.gui.updateCurrentDevice(device, dataStruct)
%
% Inputs:
%   device     - Device struct (setF.device) with .Probe, .Info fields
%   dataStruct - Data struct with fields:
%                  .stage{1}  - Raw data matrix [T x C] (or empty)
%                  .stage{4}  - Oxy data struct (fallback, optional)
%                  .time      - Time vector (optional, may be resolved)
%
% Outputs:
%   result     - Struct with fields:
%                  .curCh      - Merged channel table
%                  .curOpt     - Merged optode table
%                  .curSD      - Merged SD distance table
%                  .curChList  - Unique channel numbers
%                  .timeIndex  - Column index for time (0 = no time column)
%                  .mergedProbe - Logical, true if probes were merged
%                  .time       - Resolved time vector
%                  .sampleTime - Sample index vector
%                  .fs         - Sampling rate (Hz)
%
% See also: processFNIRS2, processFNIRS2_GUI

% Validate inputs
if length(device.Probe) == 1
    mergedProbe = true;
else
    mergedProbe = true;
    warning('Multiple Probes may not be fully supported');
end

% Merge probe tables
curCh = [];
curOpt = [];
curSD = [];

if mergedProbe
    for i = 1:length(device.Probe)
        curProbe = device.Probe{i};

        curChTable = curProbe.TableCh;
        curOptTable = curProbe.TableOpt;
        curSDTable = curProbe.TableSD;

        curChTable.ProbeInd = repmat(i, height(curChTable), 1);
        curOptTable.ProbeInd = repmat(i, height(curOptTable), 1);
        curSDTable.ProbeInd = repmat(i, height(curSDTable), 1);

        if i == 1
            curCh = curChTable;
            curOpt = curOptTable;
            curSD = curSDTable;
        else
            curCh = [curCh; curChTable]; %#ok<AGROW>
            curOpt = [curOpt; curOptTable]; %#ok<AGROW>
            curSD = [curSD; curSDTable]; %#ok<AGROW>
        end
    end

    timeIndex = find(curCh.isTime);
    if isempty(timeIndex) || device.Info.TimeIsSampleCount
        if ~device.Info.TimeIsSampleCount && isempty(timeIndex)
            % Expected for devices whose raw data has no time column (e.g.
            % NIRx), so it is shown once per session
            persistent noTimeColumnNoted
            if isempty(noTimeColumnNoted)
                noTimeColumnNoted = true;
                warning('pf2:updateCurrentDevice:noTimeColumn', ...
                    ['Time column could not be found, assuming each row contains samples only. ', ...
                     '(This note is shown once per session.)']);
            end
        end
        if isempty(timeIndex)
            timeIndex = 0;
        end
    end
else
    error('pf2_base:gui:updateCurrentDevice:notImplemented', 'Not Yet Implemented for seperate probe data,\nAssumes concatenated datasets with unique channels in the config file');
end

% Build unique channel list
[~, ui] = unique(curCh.OptodeNumber);
curChList = curCh.OptodeNumber(ui);

% Resolve time vector and sampling rate
resolvedTime = [];
sampleTime = [];
fs = [];

if mergedProbe
    rawData = dataStruct.stage{1};
    hasExistingTime = isfield(dataStruct, 'time') && ~isempty(dataStruct.time);

    if ~isempty(rawData) && ~isstruct(rawData)
        % Raw data is a matrix
        if hasExistingTime
            sampleTime = 1:size(rawData, 1);
            resolvedTime = dataStruct.time;
            fs = 1 ./ median(diff(dataStruct.time));
        elseif timeIndex == 0
            sampleTime = 1:size(rawData, 1);
            resolvedTime = (sampleTime - 1)' ./ device.Info.DefaultSamplingRate;
            fs = device.Info.DefaultSamplingRate;
        elseif device.Info.TimeIsSampleCount == 1
            sampleTime = rawData(:, timeIndex);
            resolvedTime = (sampleTime - 1) ./ device.Info.DefaultSamplingRate;
            fs = device.Info.DefaultSamplingRate;
        else
            sampleTime = 1:size(rawData, 1);
            resolvedTime = rawData(:, timeIndex);
            fs = 1 ./ median(diff(resolvedTime));
        end
    elseif hasExistingTime
        sampleTime = 1:length(dataStruct.time);
        resolvedTime = dataStruct.time;
        fs = 1 ./ median(diff(dataStruct.time));
    elseif isfield(dataStruct, 'stage') && length(dataStruct.stage) >= 4 && ~isempty(dataStruct.stage{4})
        % Try to calculate from oxy data
        oxyData = dataStruct.stage{4};
        if hasExistingTime
            resolvedTime = dataStruct.time;
            fs = 1 ./ median(diff(dataStruct.time));
            sampleTime = 1:length(resolvedTime);
        elseif timeIndex == 0
            sampleTime = 1:size(oxyData.HbO, 1);
            resolvedTime = (sampleTime - 1)' ./ device.Info.DefaultSamplingRate;
            fs = device.Info.DefaultSamplingRate;
        elseif device.Info.TimeIsSampleCount == 1
            sampleTime = oxyData.HbO(:, timeIndex);
            resolvedTime = (sampleTime - 1) ./ device.Info.DefaultSamplingRate;
            fs = device.Info.DefaultSamplingRate;
        else
            sampleTime = 1:size(oxyData.HbO, 1);
            resolvedTime = oxyData.HbO(:, timeIndex);
            fs = 1 ./ median(diff(resolvedTime));
        end
    end
end

% A counter time base (COBI .nir, see pf2_base.nirCounterTimebase) has its
% rate from the fitted counter tick; the median step would round it to a
% whole number of counts (4.99 Hz instead of 5.00 Hz on a 2000M)
if ~isempty(fs) && isfield(dataStruct, 'info') && isstruct(dataStruct.info) ...
        && isfield(dataStruct.info, 'timebase') && isfield(dataStruct.info.timebase, 'fs')
    fs = dataStruct.info.timebase.fs;
end

% Pack results
result.curCh = curCh;
result.curOpt = curOpt;
result.curSD = curSD;
result.curChList = curChList;
result.timeIndex = timeIndex;
result.mergedProbe = mergedProbe;
result.time = resolvedTime;
result.sampleTime = sampleTime;
result.fs = fs;
end
