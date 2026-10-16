function varargout = parse(fname, inputs, posSpec, nvSpec)
% PARSE Parse optional positional and name-value inputs like an arguments block
%
% Portable replacement for a function's arguments block. GNU Octave cannot
% parse name-value entries (opts.Name = default), so functions on the
% Octave-supported path declare their optional inputs as specs and call
% this instead. It reproduces the arguments-block rules that callers rely on:
%   - Optional positional inputs are filled in order until a text value
%     names a name-value argument with an even number of inputs remaining;
%     the rest are name-value pairs.
%   - Names match case-insensitively, exactly or by unique prefix; a repeated
%     name takes its last value.
%   - A name-value argument declared without a default is absent from opts
%     unless passed.
%   - Each value is converted to the declared class, checked against the
%     declared size (vectors reshape to the declared orientation), then
%     passed to the validators, as pf2_base.args.check describes.
%   - Errors use the arguments block's identifiers (MATLAB:TooManyInputs,
%     MATLAB:validation:*, and the validators' own).
%
% Reference:
%   Internal pf2 implementation; behaviour matched against MATLAB R2025b
%   argument validation.
%
% Syntax:
%   [p1, ..., pN, opts] = pf2_base.args.parse(fname, inputs, posSpec, nvSpec)
%   [p1, ..., pN]       = pf2_base.args.parse(fname, inputs, posSpec, {})
%
% Inputs:
%   fname   - Calling function name (char), used in error messages.
%   inputs  - Cell array of the inputs after the required positional ones
%             (typically varargin).
%   posSpec - N-by-5 cell, one row per optional positional input:
%             {name, default, size, class, validators}. size is '' or a
%             size spec such as '1,1' or '1,:'; class is '' or a class name;
%             validators is a cell of function handles taking the value.
%   nvSpec  - M-by-5 cell, one row per name-value argument, same columns.
%             Use pf2_base.args.noDefault() as the default for an argument
%             that must be absent when not passed.
%
% Outputs:
%   p1..pN - Optional positional values (defaults when not passed).
%   opts   - Struct of name-value values, returned when nvSpec is non-empty.
%
% Example:
%   function out = myFun(data, varargin)
%   [scale, opts] = pf2_base.args.parse('myFun', varargin, {
%       'scale', 1, '1,1', '', {@mustBePositive}
%       }, {
%       'Verbose', false, '1,1', 'logical', {}
%       });
%
% See also: pf2_base.args.check, pf2_base.args.noDefault

    if isempty(posSpec)
        posSpec = cell(0, 5);
    end
    if isempty(nvSpec)
        nvSpec = cell(0, 5);
    end
    nPos = size(posSpec, 1);
    nvNames = nvSpec(:, 1);

    % Optional positional inputs end at the first text value that names a
    % name-value argument and leaves an even number of inputs from there
    % on; otherwise that text is taken as a positional value.
    k = 0;
    while k < numel(inputs) && k < nPos
        v = inputs{k + 1};
        if ~isempty(nvNames) && isNameText(v) && mod(numel(inputs) - k, 2) == 0 ...
                && ~isempty(matchName(char(v), nvNames))
            break;
        end
        k = k + 1;
    end
    rest = inputs(k + 1:end);
    if ~isempty(rest) && isempty(nvNames)
        error('MATLAB:TooManyInputs', ...
            'Invalid argument at position %d. Function %s accepts at most %d optional positional input(s).', ...
            k + 1, fname, nPos);
    end

    % Check the structure of the name-value list (pairing, names) before
    % validating any value, as MATLAB does.
    given = struct();
    if ~isempty(nvNames)
        if mod(numel(rest), 2) ~= 0
            error('MATLAB:TooManyInputs', ['Invalid argument list. Make sure ' ...
                'name-value arguments include both the name and the value.']);
        end
        for j = 1:2:numel(rest)
            name = rest{j};
            if ~isNameText(name)
                error('MATLAB:TooManyInputs', ...
                    'Invalid argument at position %d. Function %s accepts at most %d optional positional input(s).', ...
                    k + j, fname, nPos);
            end
            idx = matchName(char(name), nvNames);
            if numel(idx) > 1
                error('MATLAB:functionValidation:AmbiguousInputName', ...
                    'Invalid argument name ''%s''. Name is ambiguous among %s.', char(name), ...
                    strjoin(strcat('''', nvNames(idx)', ''''), ', '));
            end
            if isempty(idx)
                error('MATLAB:TooManyInputs', ...
                    'Invalid argument name ''%s''. Name must be %s.', char(name), ...
                    strjoin(strcat('''', nvNames', ''''), ', '));
            end
            given.(nvNames{idx}) = rest{j + 1};
        end
    end

    varargout = cell(1, nPos + ~isempty(nvNames));
    for j = 1:nPos
        if j <= k
            value = inputs{j};
        else
            value = posSpec{j, 2};
        end
        label = sprintf('Invalid argument at position %d.', j);
        varargout{j} = pf2_base.args.check(value, posSpec{j, 3}, posSpec{j, 4}, posSpec{j, 5}, label);
    end

    if isempty(nvNames)
        return;
    end

    opts = struct();
    for j = 1:numel(nvNames)
        name = nvNames{j};
        if isfield(given, name)
            value = given.(name);
        elseif isNoDefault(nvSpec{j, 2})
            continue;
        else
            value = nvSpec{j, 2};
        end
        label = sprintf('Invalid value for ''%s'' argument.', name);
        opts.(name) = pf2_base.args.check(value, nvSpec{j, 3}, nvSpec{j, 4}, nvSpec{j, 5}, label);
    end
    varargout{end} = opts;
end

function tf = isNameText(v)
% ISNAMETEXT True for a char row or string scalar.
    tf = (ischar(v) && (isrow(v) || isempty(v))) || (isa(v, 'string') && isscalar(v));
end

function idx = matchName(name, names)
% MATCHNAME Index of NAME in NAMES: exact (case-insensitive), else unique prefix.
    idx = find(strcmpi(name, names));
    if isempty(idx) && ~isempty(name)
        idx = find(strncmpi(name, names, numel(name)));
    end
end

function tf = isNoDefault(v)
% ISNODEFAULT True for the pf2_base.args.noDefault() sentinel.
    tf = isstruct(v) && isscalar(v) && isfield(v, 'pf2ArgsNoDefault');
end
