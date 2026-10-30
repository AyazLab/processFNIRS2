function value = check(value, sizeSpec, className, validators, label)
% CHECK Convert, size-check and validate one input like an arguments block
%
% Applies an arguments-block declaration to a single value, in the order
% MATLAB uses: convert to the declared class, check (or reshape to) the
% declared size, then run each validator. Used by pf2_base.args.parse and
% directly for required positional inputs that carry a declaration.
%
% Reference:
%   Internal pf2 implementation; behaviour matched against MATLAB R2025b
%   argument validation.
%
% Syntax:
%   value = pf2_base.args.check(value, sizeSpec, className, validators)
%   value = pf2_base.args.check(value, sizeSpec, className, validators, label)
%
% Inputs:
%   value      - Input value.
%   sizeSpec   - '' (no size declaration) or a comma-separated spec such as
%                '1,1', '1,:', ':,1' or ':,3'.
%   className  - '' (no class declaration) or a class name. 'struct'
%                accepts structs and turns empty numeric, char or logical
%                arrays into field-less struct arrays; other classes are
%                converted by calling the class name as a function.
%   validators - Cell array of function handles called with the value.
%   label      - (optional) Prefix for error messages, e.g.
%                'Invalid argument at position 2.'
%
% Outputs:
%   value - Converted value.
%
% Example:
%   flag = pf2_base.args.check(1, '1,1', 'logical', {});   % -> true
%
% See also: pf2_base.args.parse

    if nargin < 5
        label = '';
    end

    if ~isempty(className)
        value = convertClass(value, className, label);
    end
    if ~isempty(sizeSpec)
        value = checkSize(value, sizeSpec, label);
    end
    for k = 1:numel(validators)
        try
            validators{k}(value);
        catch err
            msg = strtrim([label ' ' err.message]);
            if isempty(err.identifier)
                error('pf2:args:validationFailed', '%s', msg);
            end
            error(err.identifier, '%s', msg);
        end
    end
end

function value = convertClass(value, className, label)
% CONVERTCLASS Convert to the declared class, as an arguments block does.
    if isa(value, className)
        return;
    end
    converted = false;
    if strcmp(className, 'struct')
        if isempty(value) && (isnumeric(value) || ischar(value) || islogical(value))
            value = repmat(struct(), size(value));
            converted = true;
        end
    else
        try
            value = feval(className, value);
            converted = true;
        catch
        end
    end
    if ~converted
        error('MATLAB:validation:UnableToConvert', ...
            '%s Value must be of type %s or be convertible to %s.', ...
            label, className, className);
    end
end

function value = checkSize(value, sizeSpec, label)
% CHECKSIZE Enforce a size declaration such as '1,1', '1,:', ':,1' or ':,3'.
    parts = strtrim(strsplit(sizeSpec, ','));
    want = nan(1, numel(parts));   % NaN = any length (':')
    for k = 1:numel(parts)
        if ~strcmp(parts{k}, ':')
            want(k) = str2double(parts{k});
        end
    end
    sz = size(value);
    sz(end+1:numel(want)) = 1;

    if numel(sz) == numel(want) && all(isnan(want) | sz == want)
        return;
    end

    % A 0-by-0 empty takes size 0 in every free dimension and keeps the
    % fixed ones, when that still describes an empty array.
    if isequal(size(value), [0 0])
        newSize = want;
        newSize(isnan(newSize)) = 0;
        if prod(newSize) == 0
            value = reshape(value, newSize);
            return;
        end
    end

    % A scalar expands to the fixed dimensions (free dimensions become 1).
    if isscalar(value)
        newSize = want;
        newSize(isnan(newSize)) = 1;
        value = repmat(value, newSize);
        return;
    end

    % A vector (at most one non-singleton dimension, including N-D shapes
    % such as 1x1x3) reshapes to a declared vector shape, or to a column
    % when every dimension is free.
    isVectorSpec = sum(isnan(want)) == 1 && all(want(~isnan(want)) == 1);
    if sum(size(value) ~= 1) <= 1
        if isVectorSpec
            newSize = want;
            newSize(isnan(newSize)) = numel(value);
            value = reshape(value, newSize);
            return;
        elseif all(isnan(want))
            newSize = ones(1, numel(want));
            newSize(1) = numel(value);
            value = reshape(value, newSize);
            return;
        end
    end

    isVectorSpec = sum(isnan(want)) == 1 && all(want(~isnan(want)) == 1);
    if all(want == 1)
        detail = 'Value must be a scalar.';
    elseif isVectorSpec
        detail = 'Value must be a vector.';
    else
        detail = sprintf('Value must be of size %s.', strrep(sizeSpec, ',', 'x'));
    end
    error('MATLAB:validation:IncompatibleSize', '%s %s', label, detail);
end
