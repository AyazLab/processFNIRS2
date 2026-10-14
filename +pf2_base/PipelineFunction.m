classdef PipelineFunction
% PIPELINEFUNCTION Precomputed processing function for the fNIRS pipeline
%
% Encapsulates a single processing function with precomputed argument
% mappings, output indices, and a cached function handle. Supports both
% positional and name-value calling conventions.
%
% All string comparisons and index lookups happen at construction time.
% The execute() method uses only precomputed integer indices and a
% switch on uint8 enum values, so it adds zero overhead to the hot loop.
%
% Syntax:
%   pf = pf2_base.PipelineFunction(funcName, args, defaults, outputs)
%   pf = pf2_base.PipelineFunction(..., 'Name', Value)
%   pf = pf2_base.PipelineFunction.fromStruct(s)
%
% Inputs:
%   funcName - Function name string (e.g. 'pf2_lpf')
%   args     - Cell array of argument names {'x','filtType','fs','freq_cut','Nf'}
%   defaults - Cell array of default values {[], 1, [], 0.1, 50}
%   outputs  - Cell array of output names {'x'} or {'x','fchMask'}
%
% Name-Value Parameters:
%   'Style'       - 'positional' (default) or 'namevalue'
%   'Name'        - Display name (e.g. 'Low Pass Filter')
%   'Description' - Long description
%   'ValidStages' - Numeric vector of valid stages (e.g. [1,2])
%   'RequiresOD'  - Logical, true if function needs OD input
%
% Writing a custom step:
%   A step is a plain function on the MATLAB path. Its arguments are bound
%   by NAME: any arg whose name matches a reserved "special" name below is
%   auto-filled from the processing context; every other name takes its
%   value from the step's defaults/argvals. Outputs are bound the same way.
%
%   Special argument names (auto-filled inputs):
%     'x'               - data matrix (valid channels only) [T x C]
%     'fs'              - sampling frequency (Hz)
%     'fTime'           - time vector [T x 1]
%     'fchMask'         - channel mask (valid channels)
%     'ftimeChMask'     - time-channel mask [T x C]
%     'fChannelNumbers' - channel IDs
%     'fChannelSD'      - source-detector distances
%     'fProbeInfo'      - probe geometry struct
%     'fMarkers'        - event markers
%     'fAux'            - auxiliary data
%     'fAmbient'        - dark/ambient channel data
%     'fNIRstruct'      - the full fNIRS data struct
%
%   Output names that write back into the pipeline: 'x', 'fchMask',
%   'ftimeChMask'. Declare 'x' as an output to update the signal matrix.
%
%   Minimal one-in/one-out step:
%     function xz = pf2_zscore(x)
%         xz = (x - mean(x,1,'omitnan')) ./ std(x,0,1,'omitnan');
%     end
%     p = p.add('pf2_zscore', {'x'}, {[]}, {'x'});
%
% See also (full per-step execution contract):
%   pf2_base.fnirs.processStageRaw2OD, pf2_base.fnirs.processStageFilterHb
%
% Example:
%   pf = pf2_base.PipelineFunction('pf2_lpf', ...
%       {'x','filtType','fs','freq_cut','Nf'}, ...
%       {[], 1, [], 0.1, 50}, {'x'});
%   ctx.x = data; ctx.fs = 10;
%   out = pf.execute(ctx);
%
% See also: pf2_base.pf2_unpackMethod, pf2_base.fnirs.processStageRaw2OD

    properties (SetAccess = private)
        funcName          char
        funcHandle        function_handle
        name              char
        description       char
        validStages       double
        requiresOD        logical
        style             char
        role              char  % '' | 'intensity2od' | 'motion' | 'filter' | 'rejection' | 'roi' | 'transform'

        % Precomputed argument mapping
        argNames          cell
        argDefaults       cell
        specialMask       logical
        specialTypes      uint8
        customIndices     double
        customNames       cell

        % Per-argument metadata (parallel to argNames; missing entries empty)
        % Used by validators and the methods editor to render type-aware widgets.
        argTypes          cell  % {'double'|'int'|'logical'|'string'|'enum'|'special'|''}
        argChoices        cell  % {cell of valid values | []}  for enum types
        argRanges         cell  % {[min,max] | []}             for numeric types
        argUnits          cell  % {char | ''}
        argDescriptions   cell  % {char | ''}

        % Precomputed output mapping
        outputNames       cell
        xOutIdx           double
        maskOutIdx        double
        timeMaskOutIdx    double
        structOutIdx      double
        roiOutIdx         double
        nOutputs          double

        % Convenience flags
        isIntensity2OD    logical
    end

    % Special argument type enum constants
    properties (Constant, Hidden)
        SPECIAL_X               = uint8(1)
        SPECIAL_FS              = uint8(2)
        SPECIAL_FTIME           = uint8(3)
        SPECIAL_FCHMASK         = uint8(4)
        SPECIAL_FTIMECHMASK     = uint8(5)
        SPECIAL_FCHANNELNUMBERS = uint8(6)
        SPECIAL_FCHANNELSD      = uint8(7)
        SPECIAL_FPROBEINFO      = uint8(8)
        SPECIAL_FMARKERS        = uint8(9)
        SPECIAL_FNIRSTRUCT      = uint8(10)
        SPECIAL_FAUX            = uint8(11)
        SPECIAL_FAMBIENT        = uint8(12)
        SPECIAL_FMARKERTABLE    = uint8(13)
    end

    methods
        function obj = PipelineFunction(funcName, args, defaults, outputs, varargin)
        % Constructor — precomputes all argument and output mappings.

            if nargin == 0
                % Allow empty construction for array preallocation
                obj.funcName = '';
                obj.funcHandle = @(varargin) [];
                obj.name = '';
                obj.description = '';
                obj.validStages = [];
                obj.requiresOD = false;
                obj.style = 'positional';
                obj.role = '';
                obj.argNames = {};
                obj.argDefaults = {};
                obj.specialMask = logical([]);
                obj.specialTypes = uint8([]);
                obj.customIndices = [];
                obj.customNames = {};
                obj.argTypes = {};
                obj.argChoices = {};
                obj.argRanges = {};
                obj.argUnits = {};
                obj.argDescriptions = {};
                obj.outputNames = {};
                obj.xOutIdx = 0;
                obj.maskOutIdx = 0;
                obj.timeMaskOutIdx = 0;
                obj.structOutIdx = 0;
                obj.roiOutIdx = 0;
                obj.nOutputs = 0;
                obj.isIntensity2OD = false;
                return
            end

            % Parse optional name-value pairs
            p = inputParser;
            p.addParameter('Style', 'positional', @(x) ismember(x, {'positional','namevalue'}));
            p.addParameter('Name', '', @ischar);
            p.addParameter('Description', '', @ischar);
            p.addParameter('ValidStages', [], @isnumeric);
            p.addParameter('RequiresOD', false, @islogical);
            p.addParameter('Role', '', @(x) ischar(x) || isstring(x));
            p.addParameter('ArgTypes',        {}, @iscell);
            p.addParameter('ArgChoices',      {}, @iscell);
            p.addParameter('ArgRanges',       {}, @iscell);
            p.addParameter('ArgUnits',        {}, @iscell);
            p.addParameter('ArgDescriptions', {}, @iscell);
            p.parse(varargin{:});

            obj.funcName = char(funcName);
            obj.funcHandle = str2func(obj.funcName);
            obj.name = p.Results.Name;
            obj.description = p.Results.Description;
            obj.validStages = p.Results.ValidStages;
            obj.requiresOD = p.Results.RequiresOD;
            obj.style = p.Results.Style;
            obj.role = lower(char(p.Results.Role));
            % Derive isIntensity2OD from role first; fall back to name match
            % so legacy registrations without an explicit role keep working.
            if strcmp(obj.role, 'intensity2od')
                obj.isIntensity2OD = true;
            elseif isempty(obj.role) && contains(obj.funcName, 'Intensity2OD')
                obj.isIntensity2OD = true;
                obj.role = 'intensity2od';  % canonicalize
            else
                obj.isIntensity2OD = false;
            end

            % Ensure cell arrays
            if ~iscell(args), args = {args}; end
            if ~iscell(defaults), defaults = {defaults}; end
            if ~iscell(outputs), outputs = {outputs}; end

            obj.argNames = args;

            % Pad defaults to match args length
            if numel(defaults) < numel(args)
                defaults(end+1:numel(args)) = {[]};
            end
            obj.argDefaults = defaults;

            % Normalize per-arg metadata cells to length(args), padding with empty defaults.
            nA = numel(args);
            obj.argTypes        = pf2_base.PipelineFunction.padMeta(p.Results.ArgTypes,        nA, '');
            obj.argChoices      = pf2_base.PipelineFunction.padMeta(p.Results.ArgChoices,      nA, []);
            obj.argRanges       = pf2_base.PipelineFunction.padMeta(p.Results.ArgRanges,       nA, []);
            obj.argUnits        = pf2_base.PipelineFunction.padMeta(p.Results.ArgUnits,        nA, '');
            obj.argDescriptions = pf2_base.PipelineFunction.padMeta(p.Results.ArgDescriptions, nA, '');

            % Build the special argument map (persistent, shared across all instances)
            specialMap = pf2_base.PipelineFunction.specialArgMap();

            nArgs = numel(args);
            sMask = false(1, nArgs);
            sTypes = zeros(1, nArgs, 'uint8');
            custIdx = [];
            custNames = {};

            for k = 1:nArgs
                argName = args{k};
                if specialMap.isKey(argName)
                    sMask(k) = true;
                    sTypes(k) = specialMap(argName);
                else
                    custIdx(end+1) = k; %#ok<AGROW>
                    custNames{end+1} = argName; %#ok<AGROW>
                end
            end

            obj.specialMask = sMask;
            obj.specialTypes = sTypes;
            obj.customIndices = custIdx;
            obj.customNames = custNames;

            % Backfill argType='special' for special-arg slots that have no
            % explicit type. Custom-arg slots with no type stay '' (= 'auto').
            for k = 1:nA
                if sMask(k) && isempty(obj.argTypes{k})
                    obj.argTypes{k} = 'special';
                end
            end

            % Precompute output indices
            obj.outputNames = outputs;
            obj.nOutputs = numel(outputs);
            obj.xOutIdx = 0;
            obj.maskOutIdx = 0;
            obj.timeMaskOutIdx = 0;
            obj.structOutIdx = 0;
            obj.roiOutIdx = 0;

            for k = 1:numel(outputs)
                switch lower(outputs{k})
                    case 'x'
                        if obj.xOutIdx == 0
                            obj.xOutIdx = k;
                        end
                    case 'fchmask'
                        if obj.maskOutIdx == 0
                            obj.maskOutIdx = k;
                        end
                    case 'ftimechmask'
                        if obj.timeMaskOutIdx == 0
                            obj.timeMaskOutIdx = k;
                        end
                    case 'fnirstruct'
                        if obj.structOutIdx == 0
                            obj.structOutIdx = k;
                        end
                    case 'roi'
                        if obj.roiOutIdx == 0
                            obj.roiOutIdx = k;
                        end
                end
            end
        end

        function out = execute(obj, ctx)
        % EXECUTE Run the function with precomputed argument mapping.
        %
        %   out = pf.execute(ctx)
        %
        %   ctx is a struct with fields matching the special arg names:
        %     .x, .fs, .fTime, .fchMask, .ftimeChMask, .fChannelNumbers,
        %     .fChannelSD, .fProbeInfo, .fMarkers, .fNIRstruct, .fAux, .fAmbient
        %
        %   Returns a cell array of outputs.

            args = obj.argDefaults;

            % Fill special args by precomputed index
            specIdx = find(obj.specialMask);
            for ii = 1:numel(specIdx)
                k = specIdx(ii);
                switch obj.specialTypes(k)
                    case 1;  args{k} = ctx.x;
                    case 2;  args{k} = ctx.fs;
                    case 3;  args{k} = ctx.fTime;
                    case 4;  args{k} = ctx.fchMask;
                    case 5;  args{k} = ctx.ftimeChMask;
                    case 6;  args{k} = ctx.fChannelNumbers;
                    case 7;  args{k} = ctx.fChannelSD;
                    case 8;  args{k} = ctx.fProbeInfo;
                    case 9;  args{k} = ctx.fMarkers;
                    case 10; args{k} = ctx.fNIRstruct;
                    case 11; args{k} = ctx.fAux;
                    case 12; args{k} = ctx.fAmbient;
                    case 13; args{k} = ctx.fMarkerTable;
                end
            end

            % Call function
            if strcmp(obj.style, 'positional')
                [out{1:obj.nOutputs}] = obj.funcHandle(args{:});
            else
                % Name-value: special (positional) args first, then NV pairs
                posArgs = args(obj.specialMask);
                nCustom = numel(obj.customIndices);
                nvArgs = cell(1, 2*nCustom);
                for ii = 1:nCustom
                    idx = obj.customIndices(ii);
                    nvArgs{2*ii-1} = obj.customNames{ii};
                    nvArgs{2*ii}   = args{idx};
                end
                [out{1:obj.nOutputs}] = obj.funcHandle(posArgs{:}, nvArgs{:});
            end
        end

        function newObj = setParam(obj, paramName, value)
        % SETPARAM Return a new PipelineFunction with an updated default value.
        %
        %   newPf = pf.setParam('freq_cut', 0.2)

            idx = find(strcmp(obj.customNames, paramName), 1);
            if isempty(idx)
                error('pf2:PipelineFunction:unknownParam', ...
                    'Parameter ''%s'' not found. Available: %s', ...
                    paramName, strjoin(obj.customNames, ', '));
            end
            argIdx = obj.customIndices(idx);
            newDefaults = obj.argDefaults;
            newDefaults{argIdx} = value;
            newObj = pf2_base.PipelineFunction(obj.funcName, obj.argNames, ...
                newDefaults, obj.outputNames, obj.metadataNVArgs{:});
        end

        function newObj = addArg(obj, argName, defaultValue)
        % ADDARG Return a new PipelineFunction with an additional argument.
        %
        %   newPf = pf.addArg('threshold', 0.5)
        %   newPf = pf.addArg('x')              % special arg, default []
        %
        % If the argument already exists, updates its default value instead.

            if nargin < 3, defaultValue = []; end
            argName = char(argName);

            % If arg already exists, delegate to setParam for custom args
            % or silently return for special args (already mapped)
            existing = find(strcmp(obj.argNames, argName), 1);
            if ~isempty(existing)
                specialMap = pf2_base.PipelineFunction.specialArgMap();
                if specialMap.isKey(argName)
                    newObj = obj;  % already present as special arg
                else
                    newObj = obj.setParam(argName, defaultValue);
                end
                return
            end

            newArgs = [obj.argNames, {argName}];
            newDefaults = [obj.argDefaults, {defaultValue}];
            % Extend each metadata array with one empty slot for the new arg.
            nv = obj.metadataNVArgs;
            nv = pf2_base.PipelineFunction.appendEmptyMetaSlot(nv);
            newObj = pf2_base.PipelineFunction(obj.funcName, newArgs, ...
                newDefaults, obj.outputNames, nv{:});
        end

        function newObj = removeArg(obj, argName)
        % REMOVEARG Return a new PipelineFunction without the named argument.
        %
        %   newPf = pf.removeArg('Nf')
        %
        % Errors if the argument does not exist.

            argName = char(argName);
            idx = find(strcmp(obj.argNames, argName), 1);
            if isempty(idx)
                error('pf2:PipelineFunction:unknownArg', ...
                    'Argument ''%s'' not found. Available: %s', ...
                    argName, strjoin(obj.argNames, ', '));
            end

            newArgs = obj.argNames;
            newArgs(idx) = [];
            newDefaults = obj.argDefaults;
            newDefaults(idx) = [];
            % Drop the metadata slot at the same index from each metadata array.
            nv = obj.metadataNVArgs;
            nv = pf2_base.PipelineFunction.dropMetaSlot(nv, idx);
            newObj = pf2_base.PipelineFunction(obj.funcName, newArgs, ...
                newDefaults, obj.outputNames, nv{:});
        end

        function newObj = addOutput(obj, outputName)
        % ADDOUTPUT Return a new PipelineFunction with an additional output.
        %
        %   newPf = pf.addOutput('fchMask')
        %
        % If the output already exists, returns unchanged.

            outputName = char(outputName);
            if any(strcmpi(obj.outputNames, outputName))
                newObj = obj;
                return
            end

            newOutputs = [obj.outputNames, {outputName}];
            newObj = pf2_base.PipelineFunction(obj.funcName, obj.argNames, ...
                obj.argDefaults, newOutputs, obj.metadataNVArgs{:});
        end

        function nvArgs = metadataNVArgs(obj)
        % METADATANVARGS Return the metadata NV-pair cell for cloning.
        %
        % Used internally by setParam/addArg/removeArg/addOutput to propagate
        % all configuration into a freshly-constructed copy.

            nvArgs = {'Style',           obj.style, ...
                      'Name',            obj.name, ...
                      'Description',     obj.description, ...
                      'ValidStages',     obj.validStages, ...
                      'RequiresOD',      obj.requiresOD, ...
                      'Role',            obj.role, ...
                      'ArgTypes',        obj.argTypes, ...
                      'ArgChoices',      obj.argChoices, ...
                      'ArgRanges',       obj.argRanges, ...
                      'ArgUnits',        obj.argUnits, ...
                      'ArgDescriptions', obj.argDescriptions};
        end

        function val = getParam(obj, paramName)
        % GETPARAM Get the current default value for a custom parameter.

            idx = find(strcmp(obj.customNames, paramName), 1);
            if isempty(idx)
                error('pf2:PipelineFunction:unknownParam', ...
                    'Parameter ''%s'' not found. Available: %s', ...
                    paramName, strjoin(obj.customNames, ', '));
            end
            val = obj.argDefaults{obj.customIndices(idx)};
        end

        function meta = argMeta(obj, argName)
        % ARGMETA Return per-argument metadata as a struct.
        %
        %   meta = pf.argMeta('freq_cut')
        %
        % Fields: name, type, choices, range, unit, description, default,
        %         isSpecial, specialType.

            argName = char(argName);
            idx = find(strcmp(obj.argNames, argName), 1);
            if isempty(idx)
                error('pf2:PipelineFunction:unknownArg', ...
                    'Argument ''%s'' not found. Available: %s', ...
                    argName, strjoin(obj.argNames, ', '));
            end
            meta = struct( ...
                'name',        obj.argNames{idx}, ...
                'type',        obj.argTypes{idx}, ...
                'choices',     {obj.argChoices{idx}}, ...
                'range',       obj.argRanges{idx}, ...
                'unit',        obj.argUnits{idx}, ...
                'description', obj.argDescriptions{idx}, ...
                'default',     {obj.argDefaults{idx}}, ...
                'isSpecial',   obj.specialMask(idx), ...
                'specialType', obj.specialTypes(idx));
        end

        function res = validate(obj, argName, value)
        % VALIDATE Check whether `value` is acceptable for `argName`.
        %
        %   res = pf.validate('freq_cut', 0.05)
        %
        % Returns a struct with fields:
        %   .ok       (logical)  true if value passes type/range/choice checks
        %   .severity (char)     'error' | 'warning' | 'info' | 'ok'
        %   .message  (char)     human-readable description (empty if ok)
        %
        % Special args are not validated (they are filled at runtime); the
        % result is always {ok=true, severity='ok'} for them.
        % Args with no declared type accept any value.

            res = struct('ok', true, 'severity', 'ok', 'message', '');
            argName = char(argName);
            idx = find(strcmp(obj.argNames, argName), 1);
            if isempty(idx)
                res.ok = false; res.severity = 'error';
                res.message = sprintf('Unknown argument ''%s''', argName);
                return
            end
            if obj.specialMask(idx)
                return  % special args are filled at runtime
            end
            t = obj.argTypes{idx};
            if isempty(t) || strcmp(t, 'auto')
                return  % no declared type → accept anything
            end

            switch lower(t)
                case 'double'
                    if ~isnumeric(value) || ~isscalar(value) || ~isreal(value)
                        res = mkErr(argName, 'must be a real numeric scalar');
                        return
                    end
                    rng = obj.argRanges{idx};
                    if ~isempty(rng) && (value < rng(1) || value > rng(2))
                        res = mkErr(argName, sprintf('out of range [%g, %g]', rng(1), rng(2)));
                        return
                    end
                case 'int'
                    if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) ...
                            || value ~= floor(value) || ~isfinite(value)
                        res = mkErr(argName, 'must be a finite integer');
                        return
                    end
                    rng = obj.argRanges{idx};
                    if ~isempty(rng) && (value < rng(1) || value > rng(2))
                        res = mkErr(argName, sprintf('out of range [%g, %g]', rng(1), rng(2)));
                        return
                    end
                case 'logical'
                    if ~(islogical(value) || (isnumeric(value) && isscalar(value) && (value==0 || value==1)))
                        res = mkErr(argName, 'must be logical / 0 / 1');
                        return
                    end
                case 'string'
                    if ~(ischar(value) || isstring(value))
                        res = mkErr(argName, 'must be a string');
                        return
                    end
                case 'enum'
                    choices = obj.argChoices{idx};
                    if isempty(choices)
                        return  % enum without choices: skip
                    end
                    matched = false;
                    for c = 1:numel(choices)
                        if isequal(choices{c}, value) || ...
                                ((ischar(value)||isstring(value)) && ...
                                 (ischar(choices{c})||isstring(choices{c})) && ...
                                 strcmp(char(value), char(choices{c})))
                            matched = true; break
                        end
                    end
                    if ~matched
                        choiceStrs = cellfun(@formatChoice, choices, 'UniformOutput', false);
                        res = mkErr(argName, sprintf('must be one of {%s}', strjoin(choiceStrs, ', ')));
                        return
                    end
                otherwise
                    % Unknown type — silently accept.
            end

            function r = mkErr(name, msg)
                r = struct('ok', false, 'severity', 'error', ...
                    'message', sprintf('%s: %s', name, msg));
            end
            function s = formatChoice(c)
                if ischar(c) || isstring(c), s = ['''' char(c) ''''];
                else, s = num2str(c); end
            end
        end

        function issues = validateAll(obj)
        % VALIDATEALL Validate every custom-arg default; return failures.
        %
        %   issues = pf.validateAll()
        %
        % Returns a struct array (possibly empty) of validate() results
        % for every custom arg whose current default value fails.

            issues = struct('ok', {}, 'severity', {}, 'message', {}, 'arg', {});
            for k = 1:numel(obj.customNames)
                name = obj.customNames{k};
                val  = obj.argDefaults{obj.customIndices(k)};
                res  = obj.validate(name, val);
                if ~res.ok
                    res.arg = name;
                    issues(end+1) = res; %#ok<AGROW>
                end
            end
        end

        function s = params(obj)
        % PARAMS Return a struct of all custom parameters with current defaults.

            s = struct();
            for k = 1:numel(obj.customIndices)
                s.(obj.customNames{k}) = obj.argDefaults{obj.customIndices(k)};
            end
        end

        function newObj = setParams(obj, varargin)
        % SETPARAMS Bulk-set multiple parameters at once.
        %
        %   newPf = pf.setParams('freq_cut', 0.2, 'Nf', 100)
        %   newPf = pf.setParams(struct('freq_cut', 0.2, 'Nf', 100))
        %
        % Unknown keys are added via addArg. Context (special) arg keys
        % produce a warning and are skipped.

            if isempty(varargin)
                newObj = obj;
                return
            end

            % Expand struct to NV pairs
            if isstruct(varargin{1})
                s = varargin{1};
                fnames = fieldnames(s);
                nvPairs = cell(1, 2*numel(fnames));
                for k = 1:numel(fnames)
                    nvPairs{2*k-1} = fnames{k};
                    nvPairs{2*k}   = s.(fnames{k});
                end
                varargin = nvPairs;
            end

            if mod(numel(varargin), 2) ~= 0
                error('pf2:PipelineFunction:badNVPairs', ...
                    'Arguments must be name-value pairs or a struct.');
            end

            specialNames = pf2_base.PipelineFunction.specialArgNames();
            newObj = obj;
            for k = 1:2:numel(varargin)
                paramName = char(varargin{k});
                value = varargin{k+1};

                if ismember(paramName, specialNames)
                    warning('pf2:PipelineFunction:contextArg', ...
                        'Skipping context arg ''%s'' — not a tunable parameter.', paramName);
                    continue
                end

                if ismember(paramName, newObj.customNames)
                    newObj = newObj.setParam(paramName, value);
                else
                    newObj = newObj.addArg(paramName, value);
                end
            end
        end

        function tbl = args(obj)
        % ARGS Return a table of all arguments with Kind column.
        %
        %   tbl = pf.args()
        %
        %   Returns a table with columns: Position, Name, Kind, Default.
        %   Kind is 'context' for special args, 'parameter' for custom args.

            nArgs = numel(obj.argNames);
            Position = (1:nArgs)';
            Name = obj.argNames(:);
            Kind = repmat({'parameter'}, nArgs, 1);
            Default = obj.argDefaults(:);

            for k = 1:nArgs
                if obj.specialMask(k)
                    Kind{k} = 'context';
                end
            end

            tbl = table(Position, Name, Kind, Default);
        end

        function s = toStruct(obj)
        % TOSTRUCT Convert to legacy .F{i} struct format.
        %
        %   s = pf.toStruct()
        %
        %   Returns a struct with fields: .f, .args, .argvals,
        %   .default_argvals, .output, and metadata fields when non-default.

            s.f = obj.funcName;
            s.args = obj.argNames;
            s.argvals = obj.argDefaults;
            s.default_argvals = obj.argDefaults;
            s.output = obj.outputNames;

            % Preserve metadata for lossless round-trip via INI.
            % Use 'displayName' not 'name' — the GUI uses
            % isfield(F{i},'name') to detect method headers vs functions.
            % fromStruct() reads .displayName back; pf2_unpackMethod calls
            % fromStruct() on INI load, so the round-trip is preserved.
            if ~strcmp(obj.style, 'positional')
                s.style = obj.style;
            end
            if ~isempty(obj.name)
                s.displayName = obj.name;
            end
            if ~isempty(obj.description)
                s.description = obj.description;
            end
            if ~isempty(obj.validStages)
                s.validStages = obj.validStages;
            end
            if obj.requiresOD
                s.requiresOD = true;
            end
            if ~isempty(obj.role)
                s.role = obj.role;
            end
        end

        function hasX = hasSpecialArg(obj, argType)
        % HASSPECIALARG Check if function uses a specific special argument type.
        %
        %   tf = pf.hasSpecialArg('x')    % true if function takes 'x' input

            specialMap = pf2_base.PipelineFunction.specialArgMap();
            if specialMap.isKey(argType)
                hasX = any(obj.specialTypes == specialMap(argType));
            else
                hasX = false;
            end
        end

        function disp(obj)
        % DISP Compact display for PipelineFunction.

            if numel(obj) ~= 1
                fprintf('  %dx%d PipelineFunction array\n', size(obj,1), size(obj,2));
                return
            end

            if isempty(obj.funcName)
                fprintf('  PipelineFunction (empty)\n');
                return
            end

            displayName = obj.funcName;
            if ~isempty(obj.name)
                displayName = sprintf('%s (%s)', obj.name, obj.funcName);
            end

            fprintf('  PipelineFunction: %s\n', displayName);
            fprintf('    Style: %s | Outputs: %s\n', obj.style, strjoin(obj.outputNames, ', '));

            if ~isempty(obj.customNames)
                fprintf('    Parameters:\n');
                for k = 1:numel(obj.customNames)
                    val = obj.argDefaults{obj.customIndices(k)};
                    if isnumeric(val)
                        fprintf('      %s = %s\n', obj.customNames{k}, mat2str(val));
                    elseif ischar(val) || isstring(val)
                        fprintf('      %s = ''%s''\n', obj.customNames{k}, char(val));
                    else
                        fprintf('      %s = [%s]\n', obj.customNames{k}, class(val));
                    end
                end
            end
        end
    end

    methods (Static)
        function pf = fromStruct(s)
        % FROMSTRUCT Create PipelineFunction from a legacy .F{i} struct.
        %
        %   pf = pf2_base.PipelineFunction.fromStruct(s)
        %
        %   s must have fields: .f, .args, .argvals
        %   Optional: .output, .default_argvals

            if ~isfield(s, 'f') || isempty(s.f)
                error('pf2:PipelineFunction:noFunc', 'Struct must have .f field');
            end

            funcName = s.f;

            % Handle struct arrays (legacy format)
            if length(s) > 1
                args = cell(1, length(s));
                defaults = cell(1, length(s));
                for j = 1:length(s)
                    args{j} = s(j).args;
                    if isfield(s, 'default_argvals')
                        defaults{j} = s(j).default_argvals;
                    else
                        defaults{j} = s(j).argvals;
                    end
                end
            else
                args = s.args;
                defaults = s.argvals;
                if isfield(s, 'default_argvals') && ~isempty(s.default_argvals)
                    defaults = s.default_argvals;
                end
            end

            % Ensure cell arrays
            if ~iscell(args), args = {args}; end
            if ~iscell(defaults), defaults = {defaults}; end

            % Extract outputs
            if isfield(s, 'output') && ~isempty(s.output)
                outputs = s.output;
                if iscell(outputs) && ~isempty(outputs) && iscell(outputs{1})
                    outputs = outputs{1};
                end
                if ~iscell(outputs)
                    outputs = {outputs};
                end
            else
                outputs = {'x'};
            end

            % Restore metadata from struct fields first, fall back to config
            [cfgName, cfgDesc, cfgStages, cfgReqOD, cfgRole] = ...
                pf2_base.PipelineFunction.lookupFunctionMeta(funcName);

            if isfield(s, 'displayName') && ~isempty(s.displayName)
                displayName = s.displayName;
            else
                displayName = cfgName;
            end
            if isfield(s, 'description') && ~isempty(s.description)
                desc = s.description;
            else
                desc = cfgDesc;
            end
            % validStages/requiresOD describe the function's input domain,
            % which the function library owns. For a registered function the
            % library wins over flags embedded in a saved method, so a
            % corrected domain (e.g. pf2_SMAR moving from OD to raw
            % intensity) reaches methods saved before the correction. The
            % embedded flags remain the fallback for unregistered functions.
            registered = ~isempty(cfgName) || ~isempty(cfgStages);
            if registered && ~isempty(cfgStages)
                stages = cfgStages;
            elseif isfield(s, 'validStages') && ~isempty(s.validStages)
                stages = s.validStages;
            else
                stages = cfgStages;
            end
            if registered || ~isfield(s, 'requiresOD')
                reqOD = cfgReqOD;
            else
                reqOD = s.requiresOD;
            end
            % Coerce to logical: cfg INI eval gives 0/1 doubles.
            if ~islogical(reqOD), reqOD = logical(reqOD); end
            if isfield(s, 'role') && ~isempty(s.role)
                roleVal = s.role;
            else
                roleVal = cfgRole;
            end

            styleVal = 'positional';
            if isfield(s, 'style') && ~isempty(s.style)
                styleVal = s.style;
            end

            % Enrich per-arg metadata from the function library if registered.
            % Method cfgs only persist (funcName, args, argvals); per-arg
            % types/ranges/choices/units/descriptions live in the function
            % library cfg and should be re-attached on load.
            argTypes        = repmat({''}, 1, numel(args));
            argChoices      = repmat({[]}, 1, numel(args));
            argRanges       = repmat({[]}, 1, numel(args));
            argUnits        = repmat({''}, 1, numel(args));
            argDescriptions = repmat({''}, 1, numel(args));
            try
                fnCfg = pf2_base.Pipeline.loadFuncConfig();
                if isfield(fnCfg, funcName)
                    sec = fnCfg.(funcName);
                    for k = 1:numel(args)
                        an = args{k};
                        kT = [an '_type'];
                        kC = [an '_choices'];
                        kR = [an '_range'];
                        kU = [an '_unit'];
                        kD = [an '_description'];
                        if isfield(sec, kT)
                            v = sec.(kT);
                            if iscell(v) && ~isempty(v), v = v{1}; end
                            argTypes{k} = strrep(char(v), '''', '');
                        end
                        if isfield(sec, kC)
                            v = sec.(kC);
                            if (ischar(v) || isstring(v)), v = eval(char(v)); end
                            if ~iscell(v), v = {v}; end
                            argChoices{k} = v;
                        end
                        if isfield(sec, kR)
                            v = sec.(kR);
                            if (ischar(v) || isstring(v)), v = eval(char(v)); end
                            argRanges{k} = v;
                        end
                        if isfield(sec, kU)
                            v = sec.(kU);
                            if iscell(v) && ~isempty(v), v = v{1}; end
                            argUnits{k} = strrep(char(v), '''', '');
                        end
                        if isfield(sec, kD)
                            v = sec.(kD);
                            if iscell(v) && ~isempty(v), v = v{1}; end
                            argDescriptions{k} = strrep(char(v), '''', '');
                        end
                    end
                end
            catch
                % Function library unavailable — leave metadata empty.
            end

            pf = pf2_base.PipelineFunction(funcName, args, defaults, outputs, ...
                'Style', styleVal, 'Name', displayName, 'Description', desc, ...
                'ValidStages', stages, 'RequiresOD', reqOD, 'Role', roleVal, ...
                'ArgTypes', argTypes, 'ArgChoices', argChoices, ...
                'ArgRanges', argRanges, 'ArgUnits', argUnits, ...
                'ArgDescriptions', argDescriptions);
        end

        function names = specialArgNames()
        % SPECIALARGNAMES Return the canonical list of special argument names.

            names = {'x', 'fs', 'fTime', 'fchMask', 'ftimeChMask', ...
                     'fChannelNumbers', 'fChannelSD', 'fProbeInfo', ...
                     'fMarkers', 'fNIRstruct', 'fAux', 'fAmbient', ...
                     'fMarkerTable'};
        end

        function T = listAvailable(stage)
        % LISTAVAILABLE Enumerate registered PipelineFunctions from cfg.
        %
        %   T = pf2_base.PipelineFunction.listAvailable()        % all
        %   T = pf2_base.PipelineFunction.listAvailable('raw')   % stage 1 only
        %   T = pf2_base.PipelineFunction.listAvailable('oxy')   % stage 2/3 only
        %
        % Returns a MATLAB table with columns:
        %   funcName, displayName, description, role, validStages, requiresOD
        %
        % Used by editor UIs as the function-library data source.

            if nargin < 1, stage = ''; end
            stage = lower(char(stage));

            cfg = pf2_base.Pipeline.loadFuncConfig();
            names = fieldnames(cfg);

            funcName    = strings(0,1);
            displayName = strings(0,1);
            description = strings(0,1);
            role        = strings(0,1);
            validStages = cell(0,1);
            requiresOD  = false(0,1);

            for k = 1:numel(names)
                n   = names{k};
                sec = cfg.(n);
                stages = [];
                if isfield(sec, 'validStages')
                    v = sec.validStages;
                    if ischar(v) || isstring(v), v = str2num(char(v)); end %#ok<ST2NM>
                    stages = v;
                end
                % Stage filter
                if ~isempty(stage)
                    if strcmp(stage, 'raw') && ~ismember(1, stages), continue; end
                    if strcmp(stage, 'oxy') && ~any(ismember([2 3], stages)) ...
                            && ~ismember(2, stages), continue; end
                end
                dn = ''; if isfield(sec, 'Name'),        dn = strrep(char(getCellOrStr(sec.Name)),    '''',''); end
                ds = ''; if isfield(sec, 'Description'), ds = strrep(char(getCellOrStr(sec.Description)),'''',''); end
                rl = ''; if isfield(sec, 'Role'),        rl = strrep(char(getCellOrStr(sec.Role)),    '''',''); end
                ro = false;
                if isfield(sec, 'requiresOD')
                    val = sec.requiresOD;
                    ro = isnumeric(val) && val == 1;
                end

                funcName(end+1,1)    = string(n); %#ok<AGROW>
                displayName(end+1,1) = string(dn); %#ok<AGROW>
                description(end+1,1) = string(ds); %#ok<AGROW>
                role(end+1,1)        = string(rl); %#ok<AGROW>
                validStages{end+1,1} = stages; %#ok<AGROW>
                requiresOD(end+1,1)  = ro; %#ok<AGROW>
            end

            T = table(funcName, displayName, description, role, validStages, requiresOD);

            function v = getCellOrStr(x)
                if iscell(x) && ~isempty(x), v = x{1}; else, v = x; end
            end
        end

        function out = padMeta(in, n, fillValue)
        % PADMETA Normalize a metadata cell array to length n.
        %
        %   out = pf2_base.PipelineFunction.padMeta(in, n, fillValue)
        %
        % Truncates if longer; pads with fillValue if shorter; returns a
        % length-n cell with fillValue everywhere if in is empty.

            if isempty(in)
                out = repmat({fillValue}, 1, n);
                return
            end
            if ~iscell(in), in = {in}; end
            if numel(in) < n
                in(end+1:n) = {fillValue};
            elseif numel(in) > n
                in = in(1:n);
            end
            out = in;
        end

        function nv = appendEmptyMetaSlot(nv)
        % APPENDEMPTYMETASLOT Extend each metadata cell in an NV-pair list
        % returned by metadataNVArgs by one empty slot. Used by addArg.

            metaKeys = {'ArgTypes','ArgChoices','ArgRanges','ArgUnits','ArgDescriptions'};
            fillFor = {'',         [],          [],         '',        ''};
            for k = 1:numel(metaKeys)
                idx = find(strcmp(nv, metaKeys{k}), 1);
                if ~isempty(idx)
                    cellVal = nv{idx+1};
                    if ~iscell(cellVal), cellVal = {cellVal}; end
                    cellVal{end+1} = fillFor{k}; %#ok<AGROW>
                    nv{idx+1} = cellVal;
                end
            end
        end

        function nv = dropMetaSlot(nv, slot)
        % DROPMETASLOT Remove index `slot` from each metadata cell in an
        % NV-pair list returned by metadataNVArgs. Used by removeArg.

            metaKeys = {'ArgTypes','ArgChoices','ArgRanges','ArgUnits','ArgDescriptions'};
            for k = 1:numel(metaKeys)
                idx = find(strcmp(nv, metaKeys{k}), 1);
                if ~isempty(idx)
                    cellVal = nv{idx+1};
                    if ~iscell(cellVal), cellVal = {cellVal}; end
                    if slot >= 1 && slot <= numel(cellVal)
                        cellVal(slot) = [];
                    end
                    nv{idx+1} = cellVal;
                end
            end
        end

        function pf = detect(funcName)
        % DETECT Auto-discover a function's signature and build a PipelineFunction.
        %
        %   pf = pf2_base.PipelineFunction.detect('pf2_lpf')
        %   pf = pf2_base.PipelineFunction.detect('detrend_3rd_order')
        %
        % Looks up the function in the config first. If not found, parses
        % the source file's function line to extract argument and output
        % names. Special/context args are classified automatically.
        %
        % Errors if the function cannot be found on the path.

            funcName = char(funcName);

            % 1. Try config first
            cfg = pf2_base.Pipeline.loadFuncConfig();
            if isfield(cfg, funcName)
                pf = pf2_base.Pipeline.buildFromConfig(funcName, cfg.(funcName));
                return
            end

            % 2. Find source file
            srcPath = which(funcName);
            if isempty(srcPath)
                error('pf2:PipelineFunction:notFound', ...
                    'Function ''%s'' not found on the MATLAB path.', funcName);
            end
            [~, ~, ext] = fileparts(srcPath);
            if ~strcmp(ext, '.m')
                error('pf2:PipelineFunction:notSource', ...
                    'Function ''%s'' is not a .m file (found: %s).', funcName, srcPath);
            end

            % 3. Parse function line
            [argNames, outputNames] = pf2_base.PipelineFunction.parseFunctionLine(srcPath);

            % 4. Strip varargin
            vaIdx = strcmp(argNames, 'varargin');
            if any(vaIdx)
                warning('pf2:PipelineFunction:varargin', ...
                    'Function ''%s'' uses varargin — dropped from signature.', funcName);
                argNames(vaIdx) = [];
            end

            % 5. Map single unrecognized output to 'x'
            specialNames = pf2_base.PipelineFunction.specialArgNames();
            knownOutputs = [{'x'}, specialNames, {'ROI'}];
            for k = 1:numel(outputNames)
                if ~any(strcmpi(outputNames{k}, knownOutputs))
                    outputNames{k} = 'x';
                end
            end

            % 6. Defaults all []
            defaults = cell(1, numel(argNames));
            for k = 1:numel(defaults)
                defaults{k} = [];
            end

            % 7. Look up metadata
            [displayName, desc, stages, reqOD] = ...
                pf2_base.PipelineFunction.lookupFunctionMeta(funcName);

            % 8. Construct
            pf = pf2_base.PipelineFunction(funcName, argNames, defaults, ...
                outputNames, 'Name', displayName, 'Description', desc, ...
                'ValidStages', stages, 'RequiresOD', reqOD);
        end

        function pf = fromString(callStr)
        % FROMSTRING Parse a MATLAB call-syntax string into a PipelineFunction.
        %
        %   pf = pf2_base.PipelineFunction.fromString('[x]=pf2_lpf(x,1,fs,0.2,50)')
        %   pf = pf2_base.PipelineFunction.fromString('pf2_Intensity2OD(x)')
        %   pf = pf2_base.PipelineFunction.fromString('[x,fchMask]=pf2_SMAR(x,10,0.025,-1)')
        %
        % Parses the call string to extract function name, outputs, and
        % argument values. Uses detect() to get the canonical arg names,
        % then fills in parameter values from the call string. Context
        % (special) args keep [] defaults regardless of call-string values.

            callStr = strtrim(char(callStr));

            % Split on '=' to get output part and call part
            eqIdx = find(callStr == '=', 1);
            if ~isempty(eqIdx)
                outPart = strtrim(callStr(1:eqIdx-1));
                callPart = strtrim(callStr(eqIdx+1:end));

                % Parse output names (strip brackets)
                outPart = strrep(outPart, '[', '');
                outPart = strrep(outPart, ']', '');
                callOutputs = strsplit(strtrim(outPart), ',');
                callOutputs = cellfun(@strtrim, callOutputs, 'UniformOutput', false);
                callOutputs = callOutputs(~cellfun(@isempty, callOutputs));
            else
                callPart = callStr;
                callOutputs = {};
            end

            % Extract funcName and arg string from call part
            parenIdx = find(callPart == '(', 1);
            if isempty(parenIdx)
                funcName = callPart;
                argStr = '';
            else
                funcName = strtrim(callPart(1:parenIdx-1));
                % Find matching close paren
                closeIdx = find(callPart == ')', 1, 'last');
                if isempty(closeIdx)
                    argStr = callPart(parenIdx+1:end);
                else
                    argStr = callPart(parenIdx+1:closeIdx-1);
                end
            end

            % Tokenize arg string
            if isempty(strtrim(argStr))
                tokens = {};
            else
                tokens = pf2_base.PipelineFunction.tokenizeArgs(argStr);
            end

            % Detect canonical signature
            basePf = pf2_base.PipelineFunction.detect(funcName);

            % Build defaults: for each position, if arg is special → [],
            % otherwise parse the call-string token value
            specialNames = pf2_base.PipelineFunction.specialArgNames();
            newDefaults = basePf.argDefaults;
            nArgs = numel(basePf.argNames);

            for k = 1:min(numel(tokens), nArgs)
                if ismember(basePf.argNames{k}, specialNames)
                    % Context arg: keep [] regardless of call-string value
                    newDefaults{k} = [];
                else
                    newDefaults{k} = pf2_base.PipelineFunction.parseToken(tokens{k});
                end
            end

            % Use call outputs if provided, otherwise detect's outputs
            if ~isempty(callOutputs)
                outputs = callOutputs;
            else
                outputs = basePf.outputNames;
            end

            % Construct with canonical arg names but call-string values
            pf = pf2_base.PipelineFunction(funcName, basePf.argNames, ...
                newDefaults, outputs, ...
                'Name', basePf.name, 'Description', basePf.description, ...
                'ValidStages', basePf.validStages, 'RequiresOD', basePf.requiresOD);
        end

        function register(pf)
        % REGISTER Save a PipelineFunction definition to the function library.
        %
        %   pf2_base.PipelineFunction.register(pf)
        %
        % Writes the function's full signature (arguments, defaults, outputs,
        % metadata) into pf2_functions_default.cfg so that it can be looked
        % up by Pipeline.add() and the GUI. Existing entries are overwritten.
        %
        % Example:
        %   pf = pf2_base.PipelineFunction('myFilter', ...
        %       {'x','fs','cutoff'}, {[],[],0.1}, {'x'}, ...
        %       'Name', 'My Filter', 'ValidStages', [1,2]);
        %   pf2_base.PipelineFunction.register(pf);

            rootPath = pf2_base.pf2_defaultRootPath();
            cfgPath = fullfile(rootPath, 'prefs', 'pf2_functions_default.cfg');

            ini = pf2_base.external.INI('File', cfgPath);
            ini.read();

            secName = pf.funcName;

            % Remove existing section if present
            if ismember(secName, ini.Sections)
                ini.remove(secName);
            end

            % Build section struct
            sec = struct();
            if ~isempty(pf.name)
                sec.Name = sprintf('''%s''', pf.name);
            end
            if ~isempty(pf.description)
                sec.Description = sprintf('''%s''', pf.description);
            end

            % Arguments and Output as cell array expressions
            sec.Arguments = pf.argNames;
            sec.Output = pf.outputNames;

            if ~isempty(pf.validStages)
                sec.validStages = pf.validStages;
            end
            if pf.requiresOD
                sec.requiresOD = 1;
            end
            if ~isempty(pf.role)
                sec.Role = sprintf('''%s''', pf.role);
            end

            % Write custom parameter defaults
            for k = 1:numel(pf.customIndices)
                argName = pf.customNames{k};
                val = pf.argDefaults{pf.customIndices(k)};
                sec.(argName) = val;
            end

            % Write per-arg metadata (type, choices, range, unit, description)
            for k = 1:numel(pf.argNames)
                an = pf.argNames{k};
                if k <= numel(pf.argTypes) && ~isempty(pf.argTypes{k}) ...
                        && ~strcmp(pf.argTypes{k}, 'special')
                    sec.([an '_type']) = sprintf('''%s''', pf.argTypes{k});
                end
                if k <= numel(pf.argChoices) && ~isempty(pf.argChoices{k})
                    sec.([an '_choices']) = pf.argChoices{k};
                end
                if k <= numel(pf.argRanges) && ~isempty(pf.argRanges{k})
                    sec.([an '_range']) = pf.argRanges{k};
                end
                if k <= numel(pf.argUnits) && ~isempty(pf.argUnits{k})
                    sec.([an '_unit']) = sprintf('''%s''', pf.argUnits{k});
                end
                if k <= numel(pf.argDescriptions) && ~isempty(pf.argDescriptions{k})
                    sec.([an '_description']) = sprintf('''%s''', pf.argDescriptions{k});
                end
            end

            ini.add(secName, sec);
            ini.write();

            % Clear cached configs so next lookup sees the new entry
            pf2_base.PipelineFunction.clearFunctionConfigCache();
            pf2_base.Pipeline.loadFuncConfig(true);

            fprintf('Registered function: %s\n', secName);
        end
    end

    methods (Static, Hidden)
        function clearFunctionConfigCache()
        % CLEARFUNCTIONCONFIGCACHE Reset cached function config.
        %
        % Forces the next lookupFunctionMeta call to re-read from disk.
        % Called after register() modifies the config file.

            pf2_base.PipelineFunction.lookupFunctionMeta('__clear_cache__');
        end

        function m = specialArgMap()
        % SPECIALARGMAP Persistent map from arg name to uint8 type enum.

            persistent argMap
            if isempty(argMap)
                argMap = containers.Map(...
                    {'x', 'fs', 'fTime', 'fchMask', 'ftimeChMask', ...
                     'fChannelNumbers', 'fChannelSD', 'fProbeInfo', ...
                     'fMarkers', 'fNIRstruct', 'fAux', 'fAmbient', ...
                     'fMarkerTable'}, ...
                    {uint8(1), uint8(2), uint8(3), uint8(4), uint8(5), ...
                     uint8(6), uint8(7), uint8(8), uint8(9), uint8(10), ...
                     uint8(11), uint8(12), uint8(13)});
            end
            m = argMap;
        end

        function [displayName, desc, stages, reqOD, roleStr] = lookupFunctionMeta(funcName)
        % LOOKUPFUNCTIONMETA Look up function metadata from the config.
        %
        % The 5th return value (Role) is optional — older callers asking for
        % only 4 outputs continue to work unchanged.

            displayName = '';
            desc = '';
            stages = [];
            reqOD = false;
            roleStr = '';

            try
                persistent funcCfg
                if strcmp(funcName, '__clear_cache__')
                    funcCfg = [];
                    return
                end
                if isempty(funcCfg)
                    funcCfg = pf2_base.PipelineFunction.loadFunctionConfig();
                end
                if isfield(funcCfg, funcName)
                    sec = funcCfg.(funcName);
                    if isfield(sec, 'Name')
                        displayName = sec.Name;
                        if iscell(displayName), displayName = displayName{1}; end
                        displayName = strrep(displayName, '''', '');
                    end
                    if isfield(sec, 'Description')
                        desc = sec.Description;
                        if iscell(desc), desc = desc{1}; end
                        desc = strrep(desc, '''', '');
                    end
                    if isfield(sec, 'validStages')
                        stages = sec.validStages;
                        if ischar(stages) || isstring(stages)
                            stages = str2num(stages); %#ok<ST2NM>
                        end
                    end
                    if isfield(sec, 'requiresOD')
                        val = sec.requiresOD;
                        reqOD = isnumeric(val) && val == 1;
                    end
                    if isfield(sec, 'Role')
                        v = sec.Role;
                        if iscell(v) && ~isempty(v), v = v{1}; end
                        roleStr = strrep(char(v), '''', '');
                    end
                end
            catch
                % Config not available — return defaults
            end
        end

        function cfg = loadFunctionConfig()
        % LOADFUNCTIONCONFIG Load function definitions from config or global.

            cfg = struct();
            global PF2
            if ~isempty(PF2) && isfield(PF2, 'myFunctions') && isfield(PF2.myFunctions, 'cfg')
                for i = 1:length(PF2.myFunctions.cfg.Sections)
                    secName = PF2.myFunctions.cfg.Sections{i};
                    cfg.(secName) = PF2.myFunctions.cfg.(secName);
                end
                return
            end
            try
                rootPath = pf2_base.pf2_defaultRootPath();
                cfgPath = fullfile(rootPath, 'prefs', 'pf2_functions_default.cfg');
                ini = pf2_base.external.INI('File', cfgPath);
                ini.read();
                for i = 1:length(ini.Sections)
                    secName = ini.Sections{i};
                    cfg.(secName) = ini.(secName);
                end
            catch
            end
        end

        function [argNames, outputNames] = parseFunctionLine(srcPath)
        % PARSEFUNCTIONLINE Parse the function signature from a .m source file.
        %
        %   [argNames, outputNames] = pf2_base.PipelineFunction.parseFunctionLine(path)
        %
        % Reads the file line by line, skipping comments and blanks,
        % to find the first 'function' declaration. Handles '...'
        % continuation lines.

            fid = fopen(srcPath, 'r');
            if fid == -1
                error('pf2:PipelineFunction:cantRead', ...
                    'Cannot open file: %s', srcPath);
            end
            cleanupObj = onCleanup(@() fclose(fid));

            funcLine = '';
            while ~feof(fid)
                line = fgetl(fid);
                if ~ischar(line), continue; end
                stripped = strtrim(line);
                if isempty(stripped), continue; end
                if stripped(1) == '%', continue; end

                % Check for 'function' keyword
                if startsWith(stripped, 'function') && ...
                        (length(stripped) == 8 || ~isletter(stripped(9)))
                    funcLine = stripped;
                    % Handle continuation lines
                    while endsWith(strtrim(funcLine), '...')
                        funcLine = funcLine(1:end-3);
                        nextLine = fgetl(fid);
                        if ischar(nextLine)
                            funcLine = [funcLine, strtrim(nextLine)]; %#ok<AGROW>
                        end
                    end
                    break
                end
            end

            if isempty(funcLine)
                error('pf2:PipelineFunction:noFuncLine', ...
                    'No function declaration found in: %s', srcPath);
            end

            % Strip 'function' keyword
            funcLine = strtrim(funcLine(9:end));

            % Split on '=' for outputs
            eqIdx = find(funcLine == '=', 1);
            if isempty(eqIdx)
                outStr = '';
                rest = funcLine;
            else
                outStr = strtrim(funcLine(1:eqIdx-1));
                rest = strtrim(funcLine(eqIdx+1:end));
            end

            % Parse outputs
            if isempty(outStr)
                outputNames = {'x'};
            else
                outStr = strrep(outStr, '[', '');
                outStr = strrep(outStr, ']', '');
                parts = strsplit(strtrim(outStr), {',',' '});
                outputNames = cellfun(@strtrim, parts, 'UniformOutput', false);
                outputNames = outputNames(~cellfun(@isempty, outputNames));
            end

            % Parse arguments from parenthesized list
            parenOpen = find(rest == '(', 1);
            parenClose = find(rest == ')', 1, 'last');
            if isempty(parenOpen)
                argNames = {};
            else
                if isempty(parenClose)
                    argStr = rest(parenOpen+1:end);
                else
                    argStr = rest(parenOpen+1:parenClose-1);
                end
                argStr = strtrim(argStr);
                if isempty(argStr)
                    argNames = {};
                else
                    parts = strsplit(argStr, {',',' '});
                    argNames = cellfun(@strtrim, parts, 'UniformOutput', false);
                    argNames = argNames(~cellfun(@isempty, argNames));
                end
            end
        end

        function tokens = tokenizeArgs(argStr)
        % TOKENIZEARGS Bracket-and-quote-aware comma splitter.
        %
        %   tokens = pf2_base.PipelineFunction.tokenizeArgs('x,1,[2,3],''hi''')
        %
        % Splits on commas only at depth 0 and outside string literals.

            argStr = strtrim(char(argStr));
            tokens = {};
            depth = 0;
            inStr = false;
            start = 1;

            for i = 1:length(argStr)
                ch = argStr(i);

                if inStr
                    if ch == ''''
                        % Check for escaped quote ''
                        if i < length(argStr) && argStr(i+1) == ''''
                            % Skip next char (escaped quote)
                            continue
                        else
                            inStr = false;
                        end
                    end
                    continue
                end

                switch ch
                    case ''''
                        inStr = true;
                    case {'(', '[', '{'}
                        depth = depth + 1;
                    case {')', ']', '}'}
                        depth = max(0, depth - 1);
                    case ','
                        if depth == 0
                            tokens{end+1} = strtrim(argStr(start:i-1)); %#ok<AGROW>
                            start = i + 1;
                        end
                end
            end

            % Last token
            lastToken = strtrim(argStr(start:end));
            if ~isempty(lastToken)
                tokens{end+1} = lastToken;
            end
        end

        function val = parseToken(token)
        % PARSETOKEN Convert a call-string token to a MATLAB value.
        %
        %   val = pf2_base.PipelineFunction.parseToken('0.1')   % → 0.1
        %   val = pf2_base.PipelineFunction.parseToken('true')  % → true
        %   val = pf2_base.PipelineFunction.parseToken('''hi''') % → 'hi'
        %   val = pf2_base.PipelineFunction.parseToken('[]')    % → []

            token = strtrim(char(token));

            % Empty array
            if strcmp(token, '[]')
                val = [];
                return
            end

            % Boolean
            if strcmp(token, 'true')
                val = true;
                return
            end
            if strcmp(token, 'false')
                val = false;
                return
            end

            % String literal
            if length(token) >= 2 && token(1) == '''' && token(end) == ''''
                inner = token(2:end-1);
                val = strrep(inner, '''''', '''');
                return
            end

            % Numeric scalar
            num = str2double(token);
            if ~isnan(num)
                val = num;
                return
            end

            % Array literal [1,2,3]
            if token(1) == '['
                try
                    val = eval(token);
                    return
                catch
                end
            end

            % Fallback: keep as char (variable name reference)
            val = token;
        end
    end
end
