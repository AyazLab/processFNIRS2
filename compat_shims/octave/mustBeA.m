function mustBeA(value, classNames)
%MUSTBEA Validate that value is one of the given classes (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's MUSTBEA. Passes when isa(value, c) is
%   true for any listed class. The category names 'numeric', 'float' and
%   'integer' are accepted, as isa defines them. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     value      - Value to validate.
%     classNames - Class name (char or string) or a list of names (cellstr
%                  or string array).
%
%   Outputs:
%     (none) Errors with MATLAB:validators:mustBeA otherwise.
%
%   See also: isa

if ischar(classNames)
    classNames = {classNames};
elseif ~iscell(classNames)
    classNames = cellstr(classNames);
end
for k = 1:numel(classNames)
    if isa(value, classNames{k})
        return;
    end
end
error('MATLAB:validators:mustBeA', 'Value must be one of the following types: %s.', ...
    strjoin(strcat('''', classNames(:)', ''''), ', '));

end
