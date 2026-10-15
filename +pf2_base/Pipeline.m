classdef Pipeline
% PIPELINE Ordered processing chain of PipelineFunction objects
%
% Encapsulates a sequence of PipelineFunction steps that can be built
% programmatically, inspected, modified, and converted to the legacy
% method struct format consumed by processStageRaw2OD and
% processStageFilterHb.
%
% Pipeline is a value class: all mutating methods return a new copy.
%
% Syntax:
%   p = pf2_base.Pipeline(name)
%   p = pf2_base.Pipeline(name, 'Description', desc)
%   p = p.add('pf2_lpf', 'freq_cut', 0.1)
%   p = p.add(pfObj)
%   m = p.toMethod()
%
% Inputs:
%   name - Pipeline name (char)
%
% Name-Value Parameters:
%   'Description' - Human-readable description (char)
%
% Example:
%   p = pf2_base.Pipeline('myPipeline');
%   p = p.add('pf2_Intensity2OD');
%   p = p.add('pf2_MotionCorrectTDDR');
%   p = p.add('pf2_lpf', 'freq_cut', 0.2);
%   m = p.toMethod();
%
% See also: pf2_base.RawPipeline, pf2_base.OxyPipeline,
%           pf2_base.PipelineFunction

    % Types are enforced by set methods rather than inline declarations,
    % which do not parse under GNU Octave.
    properties (SetAccess = protected)
        name          = ''   % char
        description   = ''   % char
        steps         = {}   % cell of pf2_base.PipelineFunction
    end

    methods
        function obj = set.name(obj, v)
            obj.name = pf2_base.Pipeline.asChar(v);
        end

        function obj = set.description(obj, v)
            obj.description = pf2_base.Pipeline.asChar(v);
        end

        function obj = set.steps(obj, v)
            % As a 'cell' declaration: an empty numeric array becomes {}.
            if ~iscell(v)
                if isnumeric(v) && isempty(v)
                    v = cell(size(v));
                else
                    error('MATLAB:validation:UnableToConvert', ...
                        'steps must be a cell array.');
                end
            end
            obj.steps = v;
        end

        function obj = Pipeline(name, varargin)
        % Constructor.
        %
        %   p = pf2_base.Pipeline(name)
        %   p = pf2_base.Pipeline(name, 'Description', desc)

            if nargin == 0
                return
            end
            obj.name = char(name);
            if nargin > 1
                ip = inputParser;
                ip.addParameter('Description', '', @ischar);
                ip.parse(varargin{:});
                obj.description = ip.Results.Description;
            end
        end

        function obj = add(obj, funcNameOrPF, varargin)
        % ADD Append a processing step to the pipeline.
        %
        %   p = p.add(pfObj)                  % Append existing PipelineFunction
        %   p = p.add('pf2_lpf')              % Look up from config
        %   p = p.add('pf2_lpf', 'freq_cut', 0.2)  % Override defaults (NV pairs)
        %   p = p.add('pf2_lpf', struct('freq_cut', 0.2)) % ...or a param struct
        %   p = p.add('myFunc', {'x','fs','a'}, {[],[],5}, {'x'})
        %       Direct construction: funcName, args, defaults, outputs
        %
        % When adding by function name, the function is looked up in
        % pf2_functions_default.cfg.  If not found there, the function
        % is assumed to take 'x' as input and produce 'x' as output
        % (a simple pass-through signature) unless explicit args/defaults/
        % outputs are provided as positional arguments.

            if isa(funcNameOrPF, 'pf2_base.PipelineFunction')
                obj.steps{end+1} = funcNameOrPF;
                return
            end

            funcName = char(funcNameOrPF);

            % Check if the caller provided explicit args, defaults, outputs
            % as positional arguments (cell arrays) before any NV pairs
            explicitArgs = {};
            explicitDefaults = {};
            explicitOutputs = {};
            nvStart = 1;

            if numel(varargin) >= 3 && iscell(varargin{1}) && ...
                    iscell(varargin{2}) && iscell(varargin{3})
                explicitArgs = varargin{1};
                explicitDefaults = varargin{2};
                explicitOutputs = varargin{3};
                nvStart = 4;
            end

            nvPairs = varargin(nvStart:end);

            % Convenience: accept a single struct of parameters in place of
            % name-value pairs, e.g. add('pf2_lpf', struct('freq_cut', 0.2)).
            % An empty struct() is treated as "no overrides".
            if numel(nvPairs) == 1 && isstruct(nvPairs{1})
                s = nvPairs{1};
                fn = fieldnames(s);
                nvPairs = cell(1, 2 * numel(fn));
                nvPairs(1:2:end) = fn;
                for k = 1:numel(fn)
                    nvPairs{2*k} = s.(fn{k});
                end
            end

            % Try to build from config
            cfg = pf2_base.Pipeline.loadFuncConfig();

            if ~isempty(explicitArgs)
                % Direct construction with explicit signature
                pf = pf2_base.PipelineFunction(funcName, ...
                    explicitArgs, explicitDefaults, explicitOutputs);
            elseif isfield(cfg, funcName)
                pf = pf2_base.Pipeline.buildFromConfig(funcName, cfg.(funcName));
            else
                % Unknown function: assume (x) -> x
                warning('pf2:Pipeline:unknownFunc', ...
                    'Function ''%s'' not found in config. Assuming signature (x) -> x.', ...
                    funcName);
                pf = pf2_base.PipelineFunction(funcName, {'x'}, {[]}, {'x'});
            end

            % Apply NV pair overrides
            for k = 1:2:numel(nvPairs)
                pf = pf.setParam(nvPairs{k}, nvPairs{k+1});
            end

            obj.steps{end+1} = pf;
        end

        function obj = insert(obj, idx, funcNameOrPF, varargin)
        % INSERT Insert a processing step at a given position.
        %
        %   p = p.insert(2, 'pf2_lpf', 'freq_cut', 0.2)
        %   p = p.insert(1, pfObj)

            % Build the step using add logic on a temp pipeline
            temp = pf2_base.Pipeline();
            temp = temp.add(funcNameOrPF, varargin{:});
            pf = temp.steps{1};

            if idx < 1, idx = 1; end
            if idx > numel(obj.steps) + 1
                idx = numel(obj.steps) + 1;
            end

            obj.steps = [obj.steps(1:idx-1), {pf}, obj.steps(idx:end)];
        end

        function obj = remove(obj, idxOrName)
        % REMOVE Remove the step at index or by function name.
        %
        %   p = p.remove(2)
        %   p = p.remove('pf2_lpf')

            idx = obj.resolveIndex(idxOrName);
            obj.steps(idx) = [];
        end

        function obj = setParam(obj, idxOrName, paramName, value)
        % SETPARAM Update a parameter on a step (by index or name).
        %
        %   p = p.setParam(1, 'freq_cut', 0.2)
        %   p = p.setParam('pf2_lpf', 'freq_cut', 0.2)

            idx = obj.resolveIndex(idxOrName);
            obj.steps{idx} = obj.steps{idx}.setParam(paramName, value);
        end

        function obj = setParams(obj, idxOrName, varargin)
        % SETPARAMS Bulk-set multiple parameters on a step.
        %
        %   p = p.setParams(1, 'freq_cut', 0.2, 'Nf', 100)
        %   p = p.setParams('pf2_lpf', struct('freq_cut', 0.2))
        %   p = p.setParams('pf2_lpf', 'freq_cut', 0.2, 'Nf', 100)

            idx = obj.resolveIndex(idxOrName);
            obj.steps{idx} = obj.steps{idx}.setParams(varargin{:});
        end

        function obj = addArg(obj, idxOrName, argName, defaultValue)
        % ADDARG Add an argument to a step (by index or name).
        %
        %   p = p.addArg(1, 'threshold', 0.5)
        %   p = p.addArg('pf2_lpf', 'threshold', 0.5)
        %
        % If the argument already exists, updates its default value.

            idx = obj.resolveIndex(idxOrName);
            if nargin < 4, defaultValue = []; end
            obj.steps{idx} = obj.steps{idx}.addArg(argName, defaultValue);
        end

        function obj = removeArg(obj, idxOrName, argName)
        % REMOVEARG Remove an argument from a step (by index or name).
        %
        %   p = p.removeArg(1, 'Nf')
        %   p = p.removeArg('pf2_lpf', 'Nf')

            idx = obj.resolveIndex(idxOrName);
            obj.steps{idx} = obj.steps{idx}.removeArg(argName);
        end

        function obj = addOutput(obj, idxOrName, outputName)
        % ADDOUTPUT Add an output to a step (by index or name).
        %
        %   p = p.addOutput(1, 'fchMask')
        %   p = p.addOutput('pf2_lpf', 'fchMask')

            idx = obj.resolveIndex(idxOrName);
            obj.steps{idx} = obj.steps{idx}.addOutput(outputName);
        end

        function pf = getStep(obj, idxOrName)
        % GETSTEP Return the PipelineFunction (by index or name).
        %
        %   pf = p.getStep(1)
        %   pf = p.getStep('pf2_lpf')

            idx = obj.resolveIndex(idxOrName);
            pf = obj.steps{idx};
        end

        function idx = findStep(obj, funcName)
        % FINDSTEP Find the index of a step by function name.
        %
        %   idx = p.findStep('pf2_lpf')   % Returns 0 if not found

            idx = 0;
            funcName = char(funcName);
            for k = 1:numel(obj.steps)
                if strcmp(obj.steps{k}.funcName, funcName)
                    idx = k;
                    return
                end
            end
        end

        function obj = swapStep(obj, idxOrName, funcNameOrPF, varargin)
        % SWAPSTEP Replace a step (by index or name) with a different function.
        %
        %   p = p.swapStep(2, 'pf2_hpf', 'freq_cut', 0.008)
        %   p = p.swapStep('pf2_lpf', 'pf2_hpf', 'freq_cut', 0.008)
        %
        % To REORDER existing steps (not replace one), use move() instead.

            if isnumeric(funcNameOrPF)
                error('pf2_base:Pipeline:swapStepNumeric', ...
                    ['swapStep replaces a step with a FUNCTION name/object, ' ...
                     'not an index.\nTo reorder existing steps, use ' ...
                     'p = p.move(from, to).']);
            end

            idx = obj.resolveIndex(idxOrName);

            temp = pf2_base.Pipeline();
            temp = temp.add(funcNameOrPF, varargin{:});
            obj.steps{idx} = temp.steps{1};
        end

        function obj = move(obj, fromIdxOrName, toIdx)
        % MOVE Move an existing step to a new position.
        %
        %   p = p.move(3, 1)            % move step 3 to the front
        %   p = p.move('pf2_lpf', 2)    % move the lpf step to position 2
        %
        % toIdx is the final 1-based position of the moved step (clamped to
        % the valid range). Reordering preserves every step; nothing is added
        % or removed. Use swapStep() to replace a step with a different one.

            from = obj.resolveIndex(fromIdxOrName);
            if ~(isnumeric(toIdx) && isscalar(toIdx))
                error('pf2_base:Pipeline:moveBadTarget', ...
                    'move(from, toIdx): toIdx must be a scalar position.');
            end
            n = numel(obj.steps);
            toIdx = max(1, min(round(toIdx), n));

            pf = obj.steps{from};
            obj.steps(from) = [];
            obj.steps = [obj.steps(1:toIdx-1), {pf}, obj.steps(toIdx:end)];
        end

        function obj = addFromString(obj, callStr)
        % ADDFROMSTRING Parse a call-syntax string and append as a step.
        %
        %   p = p.addFromString('[x]=pf2_lpf(x,1,fs,0.2,50)')
        %   p = p.addFromString('pf2_Intensity2OD(x)')
        %
        % Delegates to PipelineFunction.fromString() for parsing.

            pf = pf2_base.PipelineFunction.fromString(callStr);
            obj.steps{end+1} = pf;
        end

        function n = numSteps(obj)
        % NUMSTEPS Return the number of steps.

            n = numel(obj.steps);
        end

        function tbl = params(obj)
        % PARAMS Aggregate table of all editable parameters across all steps.
        %
        %   tbl = p.params()
        %
        %   Returns a table with columns: Step, Function, Parameter, Value.

            Step = [];
            Function = {};
            Parameter = {};
            Value = {};

            for k = 1:numel(obj.steps)
                pf = obj.steps{k};
                if isempty(pf.customNames)
                    Step(end+1,1) = k; %#ok<AGROW>
                    Function{end+1,1} = pf.funcName; %#ok<AGROW>
                    Parameter{end+1,1} = '(none)'; %#ok<AGROW>
                    Value{end+1,1} = []; %#ok<AGROW>
                else
                    for j = 1:numel(pf.customNames)
                        Step(end+1,1) = k; %#ok<AGROW>
                        Function{end+1,1} = pf.funcName; %#ok<AGROW>
                        Parameter{end+1,1} = pf.customNames{j}; %#ok<AGROW>
                        Value{end+1,1} = pf.argDefaults{pf.customIndices(j)}; %#ok<AGROW>
                    end
                end
            end

            tbl = table(Step, Function, Parameter, Value);
        end

        function m = toMethod(obj)
        % TOMETHOD Convert to legacy method struct for processStage* functions.
        %
        %   m = p.toMethod()
        %
        %   Returns struct with .name and .F (cell array of PipelineFunction).

            m.name = obj.name;
            m.F = obj.steps;
        end

        function save(obj, stage, varargin)
        % SAVE Persist this pipeline as a named method to disk.
        %
        %   p.save('raw')
        %   p.save('oxy')
        %   p.save('raw', 'Replace', true)
        %
        % Saves the pipeline using the existing method CRUD functions
        % (pf2.methods.raw.create / pf2.methods.oxy.create). The pipeline
        % name becomes the method name.

            if nargin < 2
                error('pf2:Pipeline:noStage', ...
                    'Must specify stage: ''raw'' or ''oxy''.');
            end
            stage = lower(char(stage));

            if isempty(obj.name)
                error('pf2:Pipeline:noName', ...
                    'Pipeline must have a name before saving.');
            end

            % Convert steps to legacy struct format
            funcs = cell(1, numel(obj.steps));
            for k = 1:numel(obj.steps)
                funcs{k} = obj.steps{k}.toStruct();
            end

            switch stage
                case 'raw'
                    pf2.methods.raw.create(obj.name, funcs, varargin{:});
                case 'oxy'
                    pf2.methods.oxy.create(obj.name, funcs, varargin{:});
                otherwise
                    error('pf2:Pipeline:badStage', ...
                        'Stage must be ''raw'' or ''oxy'', got ''%s''.', stage);
            end
        end

        function s = describe(obj)
        % DESCRIBE Return a human-readable description of the pipeline.

            lines = {};
            lines{end+1} = sprintf('Pipeline: %s', obj.name);
            if ~isempty(obj.description)
                lines{end+1} = sprintf('  %s', obj.description);
            end
            lines{end+1} = sprintf('  Steps: %d', numel(obj.steps));
            for k = 1:numel(obj.steps)
                pf = obj.steps{k};
                label = pf.funcName;
                if ~isempty(pf.name)
                    label = sprintf('%s (%s)', pf.name, pf.funcName);
                end
                paramStr = '';
                if ~isempty(pf.customNames)
                    parts = cell(1, numel(pf.customNames));
                    for j = 1:numel(pf.customNames)
                        val = pf.argDefaults{pf.customIndices(j)};
                        if isnumeric(val)
                            parts{j} = sprintf('%s=%s', pf.customNames{j}, mat2str(val));
                        elseif ischar(val) || isstring(val)
                            parts{j} = sprintf('%s=''%s''', pf.customNames{j}, char(val));
                        else
                            parts{j} = sprintf('%s=[%s]', pf.customNames{j}, class(val));
                        end
                    end
                    paramStr = sprintf('  {%s}', strjoin(parts, ', '));
                end
                lines{end+1} = sprintf('    %d. %s%s', k, label, paramStr); %#ok<AGROW>
            end
            s = strjoin(lines, newline);
        end

        function disp(obj)
        % DISP Compact console display.

            if numel(obj) ~= 1
                fprintf('  %dx%d %s array\n', size(obj,1), size(obj,2), class(obj));
                return
            end
            fprintf('%s\n', obj.describe());
        end

        function out = run(obj, data, varargin) %#ok<INUSD>
        % RUN Execute the pipeline on a data struct.
        %
        % Stage-specific behavior is defined by the subclass:
        %   RawPipeline.run(data) — runs Stage 1+2 (raw → OD → Hb)
        %   OxyPipeline.run(data) — runs Stage 3 (Hb → filtered Hb)
        %
        % The base Pipeline class is stage-agnostic and refuses to run.
        % Use RawPipeline / OxyPipeline.

            error('pf2:Pipeline:runNotSupported', ...
                ['Pipeline.run requires a stage-specific subclass ' ...
                 '(RawPipeline or OxyPipeline). Got: %s'], class(obj));
        end

        function issues = validate(obj)
        % VALIDATE Return all configuration issues across the pipeline.
        %
        %   issues = p.validate()
        %
        % Returns a struct array with fields:
        %   .step     (double) step index (0 = pipeline-level issue)
        %   .funcName (char)   function name (empty for pipeline-level)
        %   .arg      (char)   argument name (empty if not arg-specific)
        %   .severity (char)   'error' | 'warning' | 'info'
        %   .message  (char)   description
        %
        % Aggregates per-step PipelineFunction.validateAll() and applies
        % cross-step ordering rules (e.g. requiresOD step must come after
        % an Intensity2OD step in raw pipelines).

            issues = struct('step', {}, 'funcName', {}, 'arg', {}, ...
                            'severity', {}, 'message', {});
            seenIntensity2OD = false;
            for k = 1:numel(obj.steps)
                pf = obj.steps{k};
                % Per-step arg validation
                stepIssues = pf.validateAll();
                for j = 1:numel(stepIssues)
                    issues(end+1) = struct( ...
                        'step',     k, ...
                        'funcName', pf.funcName, ...
                        'arg',      stepIssues(j).arg, ...
                        'severity', stepIssues(j).severity, ...
                        'message',  stepIssues(j).message); %#ok<AGROW>
                end
                % Ordering: requiresOD must follow an Intensity2OD step
                if pf.requiresOD && ~seenIntensity2OD
                    issues(end+1) = struct( ...
                        'step',     k, ...
                        'funcName', pf.funcName, ...
                        'arg',      '', ...
                        'severity', 'error', ...
                        'message',  sprintf(['Step %d (%s) requires OD ', ...
                            'input but no Intensity2OD step precedes it'], ...
                            k, pf.funcName)); %#ok<AGROW>
                end
                if pf.isIntensity2OD
                    seenIntensity2OD = true;
                end
            end
        end
    end

    methods (Access = protected)
        function idx = resolveIndex(obj, idxOrName)
        % RESOLVEINDEX Convert a numeric index or function name to a step index.

            if isnumeric(idxOrName)
                idx = idxOrName;
                if idx < 1 || idx > numel(obj.steps)
                    error('pf2:Pipeline:badIndex', ...
                        'Index %d out of range [1, %d].', idx, numel(obj.steps));
                end
            elseif ischar(idxOrName) || isstring(idxOrName)
                idx = obj.findStep(char(idxOrName));
                if idx == 0
                    error('pf2:Pipeline:stepNotFound', ...
                        'Step ''%s'' not found in pipeline.', char(idxOrName));
                end
            else
                error('pf2:Pipeline:badIndexType', ...
                    'Step identifier must be numeric index or function name string.');
            end
        end
    end

    methods (Static, Access = private)
        function v = asChar(v)
            % Convert with char(), as a 'char' property declaration does.
            try
                v = char(v);
            catch
                error('MATLAB:validation:UnableToConvert', ...
                    'Value must be convertible to char.');
            end
        end
    end

    methods (Static)
        function p = fromMethod(methodName, stage)
        % FROMMETHOD Build a Pipeline from an existing named method.
        %
        %   p = pf2_base.Pipeline.fromMethod('OD_TDDR', 'raw')
        %   p = pf2_base.Pipeline.fromMethod('takizawa_easy_lpf', 'oxy')
        %
        % Requires PF2 to be initialized.

            if nargin < 2
                stage = 'raw';
            end
            stage = lower(char(stage));

            global PF2
            if isempty(PF2) || ~isfield(PF2, 'myRawMethods')
                pf2_base.pf2_initialize();
            end

            switch stage
                case 'raw'
                    cfgField = 'myRawMethods';
                    pipeClass = @pf2_base.RawPipeline;
                case 'oxy'
                    cfgField = 'myOxyMethods';
                    pipeClass = @pf2_base.OxyPipeline;
                otherwise
                    error('pf2:Pipeline:badStage', ...
                        'Stage must be ''raw'' or ''oxy'', got ''%s''.', stage);
            end

            if ~pf2_base.isnestedfield(PF2, sprintf('%s.cfg.%s', cfgField, methodName))
                error('pf2:Pipeline:methodNotFound', ...
                    'Method ''%s'' not found in PF2.%s.', methodName, cfgField);
            end

            method = pf2_base.pf2_unpackMethod(PF2.(cfgField).cfg.(methodName));

            p = pipeClass(methodName);
            p.steps = method.F;
        end

        function p = fromSteps(name, steps)
        % FROMSTEPS Build a Pipeline from a cell array of PipelineFunction.
        %
        %   p = pf2_base.Pipeline.fromSteps('myPipe', {pf1, pf2, pf3})

            p = pf2_base.Pipeline(char(name));
            p.steps = steps;
        end
    end

    methods (Static, Hidden)
        function cfg = loadFuncConfig(clearCache)
        % LOADFUNCCONFIG Load function definitions (cached).
        %
        %   cfg = pf2_base.Pipeline.loadFuncConfig()
        %   pf2_base.Pipeline.loadFuncConfig(true)   % clear cache

            persistent funcCfg
            if nargin > 0 && clearCache
                funcCfg = [];
                cfg = struct();
                return
            end
            if isempty(funcCfg)
                funcCfg = pf2_base.PipelineFunction.loadFunctionConfig();
            end
            cfg = funcCfg;
        end

        function pf = buildFromConfig(funcName, sec)
        % BUILDFROMCONFIG Build a PipelineFunction from a config section.

            % Extract Arguments
            if isfield(sec, 'Arguments')
                args = sec.Arguments;
                if ischar(args) || isstring(args)
                    args = eval(args);
                end
                if ~iscell(args), args = {args}; end
            else
                args = {'x'};
            end

            % Extract Output
            if isfield(sec, 'Output')
                outputs = sec.Output;
                if ischar(outputs) || isstring(outputs)
                    outputs = eval(outputs);
                end
                if ~iscell(outputs), outputs = {outputs}; end
            else
                outputs = {'x'};
            end

            % Build defaults from config fields
            specialNames = pf2_base.PipelineFunction.specialArgNames();
            defaults = cell(1, numel(args));
            for k = 1:numel(args)
                argName = args{k};
                if ismember(argName, specialNames)
                    defaults{k} = [];
                elseif isfield(sec, argName)
                    val = sec.(argName);
                    if ischar(val) || isstring(val)
                        val = char(val);
                        % Try numeric conversion
                        num = str2double(val);
                        if ~isnan(num)
                            val = num;
                        end
                    end
                    defaults{k} = val;
                else
                    defaults{k} = [];
                end
            end

            % Look up metadata
            displayName = '';
            desc = '';
            stages = [];
            reqOD = false;

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

            % Optional Role tag (replaces fragile name-substring detection).
            roleStr = '';
            if isfield(sec, 'Role')
                v = sec.Role;
                if iscell(v) && ~isempty(v), v = v{1}; end
                roleStr = strrep(char(v), '''', '');
            end

            % Per-arg metadata: optional cfg keys of the form
            %   <argName>_type, <argName>_choices, <argName>_range,
            %   <argName>_unit, <argName>_description
            % (INI normalizes repeated underscores, so the cfg may use either
            %  '__' or '_' — we look for the canonical single-underscore form.)
            nA = numel(args);
            argTypes        = repmat({''}, 1, nA);
            argChoices      = repmat({[]}, 1, nA);
            argRanges       = repmat({[]}, 1, nA);
            argUnits        = repmat({''}, 1, nA);
            argDescriptions = repmat({''}, 1, nA);
            for k = 1:nA
                an = args{k};
                kT = [an '_type'];
                kC = [an '_choices'];
                kR = [an '_range'];
                kU = [an '_unit'];
                kD = [an '_description'];
                if isfield(sec, kT)
                    v = sec.(kT);
                    if iscell(v) && ~isempty(v), v = v{1}; end
                    argTypes{k} = char(strrep(char(v), '''', ''));
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
                    argUnits{k} = char(strrep(char(v), '''', ''));
                end
                if isfield(sec, kD)
                    v = sec.(kD);
                    if iscell(v) && ~isempty(v), v = v{1}; end
                    argDescriptions{k} = char(strrep(char(v), '''', ''));
                end
            end

            pf = pf2_base.PipelineFunction(funcName, args, defaults, outputs, ...
                'Name', displayName, 'Description', desc, ...
                'ValidStages', stages, 'RequiresOD', reqOD, 'Role', roleStr, ...
                'ArgTypes', argTypes, 'ArgChoices', argChoices, ...
                'ArgRanges', argRanges, 'ArgUnits', argUnits, ...
                'ArgDescriptions', argDescriptions);
        end
    end
end
