function written = writeEventsTsv(filepath, data)
% WRITEEVENTSTSV Write a BIDS _events.tsv from a recording's markers
%
% Emits the BIDS-required onset and duration columns plus trial_type (the
% marker label, resolved from the dataset marker dictionary) and value (the
% numeric marker code). Does nothing and returns false when the recording has
% no markers, so no empty events file is created.
%
% Inputs:
%   filepath - output _events.tsv path
%   data     - fNIRS data struct (uses data.markers and data.info dictionary)
%
% Outputs:
%   written - logical; true if a file was written
%
% Example:
%   pf2_base.bids.writeEventsTsv('sub-01_task-rest_events.tsv', data);
%
% See also: pf2.import.importSNIRF, pf2_base.normalizeMarkers

written = false;
if ~isstruct(data) || ~isfield(data, 'markers') || isempty(data.markers)
    return;
end

mt = pf2_base.normalizeMarkers(data.markers);
% Onsets are seconds from the first sample, as in the .snirf written by
% pf2.export.asSNIRF (time from 0 at the first sample)
origin = 0;
if isfield(data, 'time') && ~isempty(data.time)
    tFinite = data.time(isfinite(data.time));
    if ~isempty(tFinite)
        origin = tFinite(1);
    end
end
if isempty(mt) || height(mt) == 0
    return;
end

% Resolve a code->label dictionary (markerDict preferred, then eventTypes).
dictTbl = [];
if isfield(data, 'info') && isstruct(data.info)
    if isfield(data.info, 'markerDict') && ~isempty(data.info.markerDict)
        dictTbl = pf2_base.normalizeMarkerDict(data.info.markerDict);
    elseif isfield(data.info, 'eventTypes') && ~isempty(data.info.eventTypes)
        dictTbl = pf2_base.normalizeMarkerDict(data.info.eventTypes);
    end
end

% A text label column on the markers themselves takes precedence per row.
labelVar = '';
extraVars = setdiff(mt.Properties.VariableNames, ...
    {'Time', 'Code', 'Duration', 'Amplitude'}, 'stable');
for v = 1:numel(extraVars)
    col = mt.(extraVars{v});
    if isstring(col) || iscellstr(col) || iscategorical(col)
        labelVar = extraVars{v};
        break;
    end
end

n = height(mt);
headers = {'onset', 'duration', 'trial_type', 'value'};
rows = cell(n, 4);
for i = 1:n
    code = mt.Code(i);
    label = '';
    if ~isempty(labelVar)
        lv = string(mt.(labelVar)(i));
        if ~ismissing(lv) && strlength(lv) > 0
            label = char(lv);
        end
    end
    if isempty(label)
        label = dictLabel(dictTbl, code);
    end

    dur = mt.Duration(i);
    if isnan(dur)
        dur = 0;   % BIDS requires a numeric duration; 0 for instantaneous
    end

    rows{i, 1} = mt.Time(i) - origin;
    rows{i, 2} = dur;
    rows{i, 3} = label;        % '' -> 'n/a' via fmtCell
    rows{i, 4} = code;
end

pf2_base.bids.writeTsv(filepath, headers, rows);
written = true;
end

function name = dictLabel(dictTbl, code)
% Look up a code's label; '' when the dictionary lacks a usable entry.
name = '';
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
