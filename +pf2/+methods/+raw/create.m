function create(methodName, varargin)
% CREATE Create a new raw processing method programmatically
%
% Creates a new raw processing method without using the GUI. This enables
% scripted method creation for batch workflows and reproducible analysis
% setups.
%
% Syntax:
%   pf2.methods.raw.create(methodName)
%   pf2.methods.raw.create(methodName, functions)
%   pf2.methods.raw.create(..., 'Replace', true)
%
% Inputs:
%   methodName - Name for the new method (will be sanitized for INI format)
%   functions  - (optional) Cell array of function definitions, where each
%                element is a struct with fields:
%                  .f       - Function name (e.g., 'pf2_TDDR')
%                  .args    - Cell array of argument names
%                  .argvals - Cell array of argument values
%                  .output  - Output variable ('x', 'fchMask', etc.)
%
% Options (Name-Value):
%   'Replace' - If true, replace existing method with same name (default: false)
%
% Example:
%   % Create empty method
%   pf2.methods.raw.create('myMethod');
%
%   % Create method with TDDR function
%   funcs = {struct('f', 'pf2_TDDR', 'args', {{'x', 'fs'}}, ...
%                   'argvals', {{'x', 'fs'}}, 'output', 'x')};
%   pf2.methods.raw.create('myTDDR', funcs);
%
%   % Create method with multiple functions
%   f1 = struct('f', 'pf2_Intensity2OD', 'args', {{'x'}}, ...
%               'argvals', {{'x'}}, 'output', 'x');
%   f2 = struct('f', 'pf2_TDDR', 'args', {{'x', 'fs'}}, ...
%               'argvals', {{'x', 'fs'}}, 'output', 'x');
%   pf2.methods.raw.create('myPipeline', {f1, f2});
%
%   % Replace existing method
%   pf2.methods.raw.create('myMethod', funcs, 'Replace', true);
%
% See also: pf2.methods.raw.addFunction, pf2.methods.raw.list,
%           pf2.methods.raw.setMethod, pf2.methods.oxy.create

% Parse inputs
p = inputParser;
addRequired(p, 'methodName', @(x) ischar(x) || isstring(x));
addOptional(p, 'functions', {}, @iscell);
addParameter(p, 'Replace', false, @islogical);
addParameter(p, 'Context', [], @(x) isempty(x) || isstruct(x) || isobject(x));
parse(p, methodName, varargin{:});

functions = p.Results.functions;
replaceExisting = p.Results.Replace;
ctx = p.Results.Context;

% Resolve method library
methodsLib = pf2_base.resolveMethodsLib('raw', ctx);

% Sanitize method name
methodName = pf2_base.cleanNameForINI(methodName);

% Check for reserved name
if strcmpi(methodName, 'None')
    error('pf2:ReservedName', '''None'' is a reserved method name');
end
% Method libraries address methods as cfg.(methodName), which a property
% or method name of the INI class would shadow.
if pf2_base.external.INI.isReservedName(methodName)
    error('pf2:ReservedName', ...
        '''%s'' cannot be used as a method name (it is reserved by the methods library).', methodName);
end

% Check if method already exists
methodExists = ismember(methodName, methodsLib.cfg.Sections);
if methodExists && ~replaceExisting
    error('pf2:MethodExists', ...
        'Method ''%s'' already exists. Use ''Replace'', true to overwrite.', ...
        methodName);
end

% Build method structure
method = struct();
method.name = methodName;
method.F = {};

% Add functions if provided
for i = 1:length(functions)
    func = functions{i};

    % Validate function struct
    if ~isfield(func, 'f')
        error('pf2:InvalidFunction', 'Function %d missing ''f'' field', i);
    end

    % Ensure required fields exist
    if ~isfield(func, 'args'), func.args = {}; end
    if ~isfield(func, 'argvals'), func.argvals = {}; end
    if ~isfield(func, 'default_argvals'), func.default_argvals = func.argvals; end
    if ~isfield(func, 'output'), func.output = 'x'; end

    % Store function
    method.F{end+1} = func;
end

% Remove existing method if replacing
if methodExists
    methodsLib.cfg.remove(methodName);
end

% Pack method for storage (convert F to S1, S2, etc.)
packedMethod = method;
packedMethod = rmfield(packedMethod, 'F');
for j = 1:length(method.F)
    packedMethod.(sprintf('S%d', j)) = method.F{j};
end

% Add to config
methodsLib.cfg.add(methodName, packedMethod);

% Save to disk
methodsLib.cfg.write();

% Set unpacked method directly in memory.
% The INI round-trip (cfg.write -> unpackMethodsLocal) loses nested struct
% data in S1/S2/... fields. Calling unpackMethodsLocal also wipes F for
% previously created methods whose S fields were already consumed.
methodsLib.cfg.(methodName) = pf2_base.pf2_unpackMethod(method);

% Write back to global/context
pf2_base.storeMethodsLib('raw', methodsLib, ctx);

fprintf('Created raw method: %s\n', methodName);
if ~isempty(functions)
    fprintf('  Functions: %d\n', length(functions));
end

end


function myMethods = unpackMethodsLocal(myMethods)
% Delegates to pf2_base.pf2_unpackMethod for S# extraction and flattening

for i = 1:length(myMethods.cfg.Sections)
    section = myMethods.cfg.Sections{i};
    x = myMethods.cfg.(section);
    if ~isstruct(x), continue; end
    x.name = section;
    myMethods.cfg.(section) = pf2_base.pf2_unpackMethod(x);
end

end
