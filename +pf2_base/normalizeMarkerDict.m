function d = normalizeMarkerDict(x)
% NORMALIZEMARKERDICT Standardize a marker dictionary into a canonical table
%
% Converts a code->label dictionary from any supported form into a canonical
% MATLAB table keyed by Code, with a Label column and any additional
% per-code attribute columns preserved. This is the dataset-level mapping
% that gives marker codes meaning (consumed by labelMarkers, defineBlocks,
% and plotting) and is the unifying target for source-specific formats such
% as BIDS events.tsv (eventTypes) and the COBI .nir Marker Dictionary.
%
% Syntax:
%   d = pf2_base.normalizeMarkerDict(x)
%
% Inputs:
%   x - Dictionary in any of these forms:
%       table          - Variables mapped onto Code/Label by name (synonyms
%                        such as marker/value/id and name/description/type are
%                        recognized); unrecognized variables are kept as
%                        per-code attributes.
%       {code,'Label'} - Two-column cell array (extra columns kept as Attr3..).
%       containers.Map - keys are codes, values are labels.
%       []             - Empty (returns a 0-row canonical dict).
%
% Outputs:
%   d - Dictionary table with one row per unique Code:
%       .Code  - Numeric marker code
%       .Label - String label
%       (...)  - Any additional per-code attribute columns, preserved
%       Rows are de-duplicated by Code (first occurrence wins).
%
% Notes:
%   - Codes are coerced to numeric: text-typed code columns are parsed by VALUE
%     (str2double), not by character codepoint. Rows whose Code cannot be parsed
%     (NaN) are dropped by the Code-dedupe step, so a malformed entry silently
%     disappears rather than poisoning the dictionary.
%   - De-duplication keeps the FIRST occurrence of each Code (callers relying on
%     "last wins" must reorder before calling).
%   - containers.Map and cell inputs assume numeric codes; non-numeric Map keys
%     are coerced and may not behave as intended.
%
% Example:
%   d = pf2_base.normalizeMarkerDict({49,'Stroop'; 50,'Control'});
%   d = pf2_base.normalizeMarkerDict(data.info.log_info.MarkerDict); % COBI
%
% See also: pf2.data.getMarkerDict, pf2.data.setMarkerDict,
%           pf2.data.labelMarkers, pf2_base.normalizeMarkers

canon = {'Code', 'Label'};

% --- Empty input ---------------------------------------------------------
if isempty(x)
    d = table(zeros(0, 1), strings(0, 1), 'VariableNames', canon);
    return;
end

% --- containers.Map ------------------------------------------------------
if isa(x, 'containers.Map')
    k = keys(x);
    v = values(x);
    codes = cellfun(@(c) double(c), k(:));
    labels = string(v(:));
    d = dedupeByCode(table(codes, labels, 'VariableNames', canon));
    return;
end

% --- Cell array {code,'Label', ...} -------------------------------------
if iscell(x)
    if size(x, 2) < 2
        error('pf2:normalizeMarkerDict:badCell', ...
            'Cell dictionary needs at least two columns {code, label}.');
    end
    % Parse codes by value, so a text code '49' becomes 49 (not its
    % codepoint). Element by element: Octave's string() of a numeric cell
    % does not keep one element per row.
    codes = nan(size(x, 1), 1);
    for r = 1:size(x, 1)
        v = x{r, 1};
        if (isnumeric(v) || islogical(v)) && isscalar(v)
            codes(r) = double(v);
        else
            codes(r) = str2double(v);
        end
    end
    labels = reshape(string(x(:, 2)), [], 1);
    d = table(codes, labels, 'VariableNames', canon);
    for c = 3:size(x, 2)
        col = x(:, c);
        try
            col = cell2mat(col);
        catch
            col = string(col);
        end
        d.(sprintf('Attr%d', c)) = col;
    end
    d = dedupeByCode(d);
    return;
end

% --- Table ---------------------------------------------------------------
if istable(x)
    d = dedupeByCode(normalizeDictTable(x, canon));
    return;
end

error('pf2:normalizeMarkerDict:badType', ...
    'Marker dictionary must be a table, cell array, containers.Map, or []; got %s.', class(x));

end

%%_Subfunctions_________________________________________________________

function T = normalizeDictTable(T, canon)
% NORMALIZEDICTTABLE Map an existing dictionary table onto Code/Label + extras
vn = T.Properties.VariableNames;
lvn = lower(vn);
nRows = height(T);
used = false(1, numel(vn));

% Code: exact synonyms broad; substring conservative
[Code, used] = pick(T, lvn, used, ...
    {'code', 'markercode', 'value', 'marker', 'id'}, {'code', 'marker'}, ...
    (1:nRows)', true);
% Label: exact synonyms broad; substring conservative
[Label, used] = pick(T, lvn, used, ...
    {'label', 'name', 'description', 'condition', 'type', 'trial_type'}, ...
    {'label', 'name', 'desc', 'condition'}, strings(nRows, 1), false);

out = table(Code, Label, 'VariableNames', canon);

extras = find(~used);
for k = 1:numel(extras)
    name = matlab.lang.makeValidName(vn{extras(k)});
    out.(name) = T{:, extras(k)};
end

T = out;
end

function [col, used] = pick(T, lvn, used, exactSyns, containsSyns, default, asNumeric)
% PICK First unclaimed variable matching a synonym, coerced to the wanted type
idx = firstMatch(lvn, used, exactSyns, containsSyns);
if isempty(idx)
    col = default;
else
    col = T{:, idx};
    used(idx) = true;
    if asNumeric && ~isnumeric(col)
        col = double(str2double(string(col)));
    elseif ~asNumeric
        col = string(col);
    end
end
end

function idx = firstMatch(names, used, exactSyns, containsSyns)
% FIRSTMATCH Locate an unclaimed variable: exact synonyms, then substring
idx = [];
for s = 1:numel(exactSyns)
    hit = find(strcmp(names, exactSyns{s}) & ~used, 1);
    if ~isempty(hit); idx = hit; return; end
end
for s = 1:numel(containsSyns)
    hit = find(contains(names, containsSyns{s}) & ~used, 1);
    if ~isempty(hit); idx = hit; return; end
end
end

function d = dedupeByCode(d)
% DEDUPEBYCODE Keep one row per Code (first occurrence), drop NaN codes
if height(d) == 0; return; end
d = d(~isnan(d.Code), :);
[~, ia] = unique(d.Code, 'stable');
d = d(ia, :);
end
