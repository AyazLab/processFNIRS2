function data = infoFromTable(data, T, varargin)
% INFOFROMTABLE Write table columns back into .info fields of fNIRS structs
%
% Maps table rows positionally to fNIRS data structs: row 1 updates
% data{1}.info, row 2 updates data{2}.info, etc. By default, table columns
% are merged into existing .info fields, preserving any fields not present
% in the table. Missing values (NaN, "", NaT) are skipped rather than
% written, so existing .info values are preserved for those entries.
%
% A single field name and value can be passed instead of a table to set
% one field across all structs. A scalar value is broadcast; a vector is
% mapped positionally.
%
% Syntax:
%   data = pf2.data.infoFromTable(data, T)
%   data = pf2.data.infoFromTable(data, T, 'Overwrite', false)
%   data = pf2.data.infoFromTable(data, T, 'Clear', true)
%   data = pf2.data.infoFromTable(data, fieldName, value)
%   data = pf2.data.infoFromTable(data, fieldName, scalarValue)
%
% Inputs:
%   data      - fNIRS data structure or cell array of structures, each with
%               an .info field (or one will be created).
%   T         - MATLAB table with one row per struct. Column names become
%               .info field names. height(T) must equal numel(data).
%   fieldName - (Alternative) Single field name [char|string]. When used,
%               the third argument is the value to assign.
%   value     - Value(s) to assign. Scalar is broadcast to all structs;
%               vector must have numel(data) elements.
%
% Name-Value Parameters:
%   'Overwrite' - Whether to overwrite existing .info fields that appear
%                 in the table (default: true). When false, existing fields
%                 are preserved even if the table has a value for them.
%   'Clear'     - If true, replaces .info entirely with table row contents,
%                 removing fields not in the table (default: false).
%
% Outputs:
%   data - Same structure(s) with .info fields updated from table values.
%          Returns same type as input (struct -> struct, cell -> cell).
%
% Example:
%   T = pf2.data.infoToTable(allData);
%   T.Group = ["A"; "B"; "A"];
%   allData = pf2.data.infoFromTable(allData, T);
%
%   % Add new field without overwriting existing ones
%   allData = pf2.data.infoFromTable(allData, T, 'Overwrite', false);
%
%   % Set single field: scalar broadcast
%   allData = pf2.data.infoFromTable(allData, 'Group', 'Control');
%
%   % Set single field: per-element vector
%   allData = pf2.data.infoFromTable(allData, 'Group', ["A"; "B"; "C"]);
%
% See also: pf2.data.infoToTable, pf2.data.importInfo

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[value, opts] = pf2_base.args.parse('infoFromTable', varargin, {
    'value', ("__pf2_infoFromTable_novalue__"), '', '', {}
    }, {
    'Overwrite', (true), '1,1', 'logical', {}
    'Clear',     (false), '1,1', 'logical', {}
    });

% A sentinel default marks "value was not supplied" (single-field mode
% requires an explicit value argument, matching the original ~isempty(varargin)
% guard). A real supplied value of [] must still trigger single-field mode.
valueSupplied = ~(isstring(value) && isscalar(value) && ...
    value == "__pf2_infoFromTable_novalue__");

% --- Detect single-field mode: infoFromTable(data, fieldName, value) ---
if (ischar(T) || (isstring(T) && isscalar(T))) && valueSupplied
    fieldName = char(T);

    % Normalize to cell array
    inputWasCell = iscell(data);
    if ~inputWasCell
        dataCell = {data};
    else
        dataCell = data;
    end
    N = numel(dataCell);

    % Expand scalar to vector
    isScalarVal = isscalar(value) || (ischar(value) && size(value, 1) <= 1);
    if isScalarVal
        % Convert to char for .info convention if string
        if isstring(value)
            value = char(value);
        end
        for i = 1:N
            d = dataCell{i};
            if ~isfield(d, 'info') || ~isstruct(d.info)
                d.info = struct();
            end
            d.info.(fieldName) = value;
            dataCell{i} = d;
        end
    else
        % Vector: must match length
        if numel(value) ~= N
            error('pf2:data:infoFromTable:sizeMismatch', ...
                'Value has %d elements but data has %d elements.', numel(value), N);
        end
        for i = 1:N
            d = dataCell{i};
            if ~isfield(d, 'info') || ~isstruct(d.info)
                d.info = struct();
            end
            v = value(i);
            if iscell(v), v = v{1}; end
            if isstring(v), v = char(v); end
            d.info.(fieldName) = v;
            dataCell{i} = d;
        end
    end

    if inputWasCell
        data = dataCell;
    else
        data = dataCell{1};
    end
    return;
end

% --- Table mode: parse inputs ---
overwrite = opts.Overwrite;
clearMode = opts.Clear;

% --- Normalize to cell array ---
inputWasCell = iscell(data);
if ~inputWasCell
    dataCell = {data};
else
    dataCell = data;
end
N = numel(dataCell);

% --- Validate dimensions ---
if height(T) ~= N
    error('pf2:data:infoFromTable:sizeMismatch', ...
        'Table has %d rows but data has %d elements.', height(T), N);
end

colNames = T.Properties.VariableNames;

% --- Write table rows into .info ---
for i = 1:N
    d = dataCell{i};

    if clearMode
        info = struct();
    elseif isfield(d, 'info') && isstruct(d.info)
        info = d.info;
    else
        info = struct();
    end

    for c = 1:numel(colNames)
        fn = colNames{c};

        % Skip if Overwrite is false and field already exists
        if ~overwrite && ~clearMode && isfield(info, fn)
            continue;
        end

        % Extract value from table
        val = T.(fn)(i);

        % Unwrap cell
        if iscell(val)
            val = val{1};
        end

        % Skip missing values
        if isMissingValue(val)
            continue;
        end

        % Convert string to char for consistency with .info convention
        if isstring(val)
            val = char(val);
        end

        info.(fn) = val;
    end

    d.info = info;
    dataCell{i} = d;
end

% --- Return same type as input ---
if inputWasCell
    data = dataCell;
else
    data = dataCell{1};
end

end

% =========================================================================
% Local functions
% =========================================================================

function tf = isMissingValue(val)
% Check if a value is a type-appropriate "missing" that should be skipped
    if isstring(val) && (ismissing(val) || val == "")
        tf = true;
    elseif ischar(val) && isempty(val)
        tf = true;
    elseif isnumeric(val) && isscalar(val) && isnan(val)
        tf = true;
    elseif isdatetime(val) && isnat(val)
        tf = true;
    elseif isduration(val) && isnan(val)
        tf = true;
    elseif iscategorical(val) && isundefined(val)
        tf = true;
    else
        tf = false;
    end
end
