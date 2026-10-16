function out = labelMarkers(data, varargin)
% LABELMARKERS Attach categorical labels to marker codes
%
% Adds (or updates) a categorical column on the marker table that maps each
% marker Code to a human-readable label, so event codes carry meaning that
% rides along with the markers through preprocessing, splicing, and grouping.
% The mapping comes from an explicit code->label list or, when omitted, from
% data.info.eventTypes (e.g. populated from a BIDS events.tsv on import).
%
% Syntax:
%   data    = pf2.data.labelMarkers(data)                 % use marker dictionary
%   data    = pf2.data.labelMarkers(data, map)            % explicit map
%   markers = pf2.data.labelMarkers(markerTable, map)     % operate on a table
%   ...     = pf2.data.labelMarkers(..., 'Name', Value)
%   allData = pf2.data.labelMarkers(allData, ...)         % cell array
%
% Inputs:
%   data - fNIRS data struct with a .markers table (and optionally
%          .info.eventTypes), a marker table directly, or a cell array of
%          structs.
%   map  - (Optional) Code->label mapping as a two-column cell array
%          {code1,'Label1'; code2,'Label2'; ...}. Column 1 is numeric codes,
%          column 2 is char/string labels. If omitted, the dataset's marker
%          dictionary is used (pf2.data.getMarkerDict: markerDict ->
%          eventTypes -> COBI MarkerDict), which must yield at least one label.
%
% Name-Value Parameters:
%   'VarName'  - Name of the label column to create (default: 'Label').
%   'Ordinal'  - Make the categorical ordinal, in map order (default: false).
%   'Categories' - Explicit category order (cellstr/string). Default: the
%                  label order in the map (unique, stable).
%
% Outputs:
%   out - Same form as the input (struct, table, or cell array) with the
%         marker table carrying a categorical label column. Codes with no
%         mapping become <undefined>.
%
% Algorithm:
%   1. Cell array  -> apply recursively to each element.
%   2. Resolve the map: an explicit {code,'Label'} cell takes precedence;
%      otherwise (struct input) fall back to pf2.data.getMarkerDict and use its
%      labelled rows. A table input with no map is an error.
%   3. Normalize the markers, build a per-row string label by matching each
%      Code against the map, then convert to a categorical with categories
%      from 'Categories' (or, by default, the unique map labels in order) and
%      ordinality from 'Ordinal'. Unmatched codes become <undefined>.
%
% Notes:
%   - Re-calling with the same 'VarName' replaces that column (MATLAB table
%     assignment semantics); pass a different 'VarName' to keep multiple
%     labellings (e.g. 'Condition' and 'Difficulty').
%   - 'Ordinal' lets categories be compared with < / > in map (or 'Categories')
%     order; labels outside the category set become <undefined>.
%   - Empty markers are handled gracefully (an empty categorical column).
%
% Example:
%   data = pf2.data.labelMarkers(data, {49,'Stroop'; 50,'Control'});
%   summary(data.markers.Label)              % counts per condition
%   isStroop = data.markers.Label == 'Stroop';
%
%   % Auto-label from BIDS events.tsv mapping captured at import
%   data = pf2.import.importSNIRF('sub-01_nirs.snirf');
%   data = pf2.data.labelMarkers(data);      % uses data.info.eventTypes
%
% See also: pf2.data.defineBlocks, pf2.data.getMarkers, pf2_base.normalizeMarkers

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[map, opts] = pf2_base.args.parse('labelMarkers', varargin, {
    'map', ([]), '', '', {}
    }, {
    'VarName',    ('Label'), '', '', {@mustBeTextScalar}
    'Ordinal',    (false), '1,1', 'logical', {}
    'Categories', ([]), '', '', {}
    });

% --- Cell array input: apply to each element ---
if iscell(data)
    fwd = namedargs2cell(opts);
    out = data;
    for ci = 1:numel(data)
        out{ci} = pf2.data.labelMarkers(data{ci}, map, fwd{:});
    end
    return;
end

varName = char(opts.VarName);
ordinal = opts.Ordinal;
explicitCats = opts.Categories;

% --- Resolve the marker table and (if struct) the eventTypes fallback ---
isStructInput = isstruct(data) && isfield(data, 'markers');
if isStructInput
    if isempty(map)
        % Fall back to the dataset's marker dictionary (markerDict ->
        % eventTypes -> COBI MarkerDict, resolved by getMarkerDict).
        dict = pf2.data.getMarkerDict(data);
        labeled = dict(~ismissing(dict.Label), :);
        if isempty(labeled)
            error('pf2:labelMarkers:noMap', ...
                ['No code->label map supplied and the dataset has no marker ', ...
                 'dictionary. Pass a {code,''Label''} mapping or set one via ', ...
                 'pf2.data.setMarkerDict.']);
        end
        map = [num2cell(labeled.Code), cellstr(labeled.Label)];
    end
    mt = pf2_base.normalizeMarkers(data.markers);
elseif istable(data)
    if isempty(map)
        error('pf2:labelMarkers:noMap', ...
            'A {code,''Label''} mapping is required when labeling a table directly.');
    end
    mt = pf2_base.normalizeMarkers(data);
else
    error('pf2:labelMarkers:badInput', ...
        'First argument must be an fNIRS struct with .markers, a marker table, or a cell array.');
end

% --- Build the categorical label column ---
mapCodes = map(:, 1);
if iscell(mapCodes)
    mapCodes = cell2mat(mapCodes);
end
mapLabels = string(map(:, 2));

codes = mt.Code;
labelStr = strings(height(mt), 1);
labelStr(:) = missing;
[tf, loc] = ismember(codes, mapCodes(:));
labelStr(tf) = mapLabels(loc(tf));

if isempty(explicitCats)
    cats = unique(mapLabels, 'stable');
else
    cats = string(explicitCats);
end

mt.(varName) = categorical(labelStr, cats, 'Ordinal', ordinal);

% --- Return in the same form as input ---
if isStructInput
    data.markers = mt;
    out = data;
else
    out = mt;
end

end
