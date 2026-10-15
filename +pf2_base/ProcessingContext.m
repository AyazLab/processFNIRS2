classdef ProcessingContext < handle
    % PROCESSINGCONTEXT Encapsulates all processing settings for fNIRS analysis
    %
    % ProcessingContext provides an alternative to global variables (PF2, setF)
    % for managing processing configuration. It enables:
    %   - Isolated testing without global state pollution
    %   - Parallel processing with different settings per worker
    %   - Reproducible analyses by saving/loading contexts
    %   - Explicit dependency injection into processing functions
    %
    % Isolation guarantee:
    %   When a context is passed to processFNIRS2 (via 'Context', ctx), the
    %   processing path is fully isolated from global state: PF2 and setF are
    %   neither initialized nor written. Every setting, method, and the device
    %   are threaded as locals sourced from the context. After such a call the
    %   globals are byte-identical to their pre-call state, so context-based
    %   processing is reproducible and safe for parallel/worker use.
    %
    % For backward compatibility, the legacy (no-context) path continues to
    % read and write globals, and functions that accept a Context parameter
    % fall back to reading from globals when no context is provided.
    %
    % Syntax:
    %   ctx = ProcessingContext()           % Create with defaults
    %   ctx = ProcessingContext.fromGlobals() % Create from current global state
    %
    % Properties:
    %   DPF Settings:
    %     dpfMode       - 'None', 'Fixed', 'Calc', or 'PPF' (default: 'Calc')
    %     dpfFixedValue - Fixed DPF value (default: 5.93)
    %     subjectAge    - Age for DPF calculation (default: 25)
    %     pvc           - Partial-volume correction divisor (>=1) applied to the
    %                     Fixed/Calc DPF: L = SD.*DPF./pvc. Get a principled
    %                     value from pf2_base.fnirs.strangmanPVC. (default: [] ->1)
    %     ppf           - Complete effective pathlength factor (escape hatch)
    %                     used when dpfMode is 'PPF': L = SD.*ppf, no DPF/PVC.
    %                     Scalar or per-wavelength [ppf1 ppf2]. (default: [])
    %
    %   Baseline Settings:
    %     baselineStartTime - Baseline start in seconds (default: 0)
    %     baselineLength    - Baseline duration in seconds (default: 10)
    %     useAbsoluteTime   - Use absolute vs relative time (default: false)
    %     dirtyBaseline     - Use entire signal as baseline (default: false)
    %
    %   Method Configuration:
    %     rawMethodName   - Name of raw processing method
    %     rawMethod       - Unpacked raw method struct
    %     oxyMethodName   - Name of oxy processing method
    %     oxyMethod       - Unpacked oxy method struct
    %     rawMethodsLib   - Library of available raw methods
    %     oxyMethodsLib   - Library of available oxy methods
    %
    %   Device Configuration:
    %     device          - Device configuration struct (from setF.device)
    %
    %   Quality Control:
    %     rejectLevel     - Channel rejection threshold (default: 0)
    %     processRejected - Process rejected channels anyway (default: false)
    %
    %   Output Options:
    %     outputLegacyMarkers - Output markers in legacy format (default: false)
    %
    % Example:
    %   % Create context for testing
    %   ctx = ProcessingContext();
    %   ctx.dpfMode = 'Fixed';
    %   ctx.dpfFixedValue = 6.0;
    %   ctx.baselineLength = 5;
    %   result = processFNIRS2(data, 'Context', ctx);
    %
    %   % Parallel processing with different ages. Snapshot ONCE in the client
    %   % (fromGlobals reads client globals; on a parfor worker they are empty),
    %   % then take an independent copy() per iteration -- a plain ctx = base
    %   % would alias the same handle across workers.
    %   baseCtx = ProcessingContext.fromGlobals();
    %   parfor i = 1:numSubjects
    %       ctx = baseCtx.copy();
    %       ctx.subjectAge = ages(i);
    %       results{i} = processFNIRS2(data{i}, 'Context', ctx);
    %   end
    %
    %   % Save context for reproducibility
    %   ctx = ProcessingContext.fromGlobals();
    %   save('analysis_settings.mat', 'ctx');
    %
    % Property types and validators are enforced by set methods rather than
    % inline declarations (e.g. 'dpfMode (1,:) char {mustBeMember(...)}'),
    % and copy() is implemented here rather than inherited from
    % matlab.mixin.Copyable, so the class also parses under GNU Octave.
    % The set methods convert, size-check and validate in the same order as
    % the inline declarations, with the same error identifiers. One
    % difference: objects such as datetime or categorical assigned to a
    % struct-valued property now error instead of being converted with
    % struct().
    %
    % See also: processFNIRS2, pf2_base.pf2_initialize

    properties (Constant, Hidden)
        % Passed to a subclass constructor by copy() to skip any expensive
        % initialization; the copy's properties are overwritten afterwards.
        COPY_TOKEN = '__pf2_ProcessingContext_copy__'
    end

    properties
        % DPF (Differential Pathlength Factor) settings
        dpfMode = 'Calc'           % 'None' | 'Fixed' | 'Calc' | 'PPF'
        dpfFixedValue = 5.93       % positive scalar
        subjectAge = 25            % positive scalar

        % Partial-volume correction applied to the fixed or age-calculated DPF:
        % L = SD.*DPF./pvc. Empty means 1 (no correction). A scalar or per-optode
        % numeric vector (each >=1), or the string 'auto' for a per-channel value
        % derived from each channel's separation (Strangman 2014). Left untyped
        % so 'auto' and numeric forms are both accepted.
        pvc = []

        % Complete effective pathlength factor (escape hatch), used when
        % dpfMode == 'PPF': L = SD.*ppf, with no DPF/PVC. Scalar or [ppf1 ppf2].
        ppf = zeros(1, 0)          % double row

        % Baseline settings
        baselineStartTime = 0      % scalar
        baselineLength = 10        % non-negative scalar
        useAbsoluteTime = false    % logical scalar
        windowStartTime = 0        % scalar
        dirtyBaseline = false      % logical scalar

        % Method configuration
        rawMethodName = 'None'     % char row
        rawMethod = struct()
        oxyMethodName = 'None'     % char row
        oxyMethod = struct()

        % Method libraries (loaded from config files)
        rawMethodsLib = struct()
        oxyMethodsLib = struct()

        % Device configuration
        device = struct()

        % Quality control
        rejectLevel = 0            % scalar in [0, 1]
        processRejected = false    % logical scalar

        % Output options
        outputLegacyMarkers = false  % logical scalar

        % Paths
        rootPath = ''              % char row
    end

    methods
        function obj = ProcessingContext(varargin)
            % PROCESSINGCONTEXT Create a new processing context with defaults
            %
            % The context is initialized with sensible defaults. Use
            % fromGlobals() to create a context matching current global state.
            % Any input (copy() passes COPY_TOKEN) is ignored here.

            obj.rootPath = pf2_base.pf2_defaultRootPath();
        end

        function setRawMethod(obj, methodName)
            % SETRAWMETHOD Set the raw processing method by name
            %
            % Syntax:
            %   ctx.setRawMethod('OD_TDDR')
            %
            % The method must exist in rawMethodsLib.

            if isempty(obj.rawMethodsLib) || ~isfield(obj.rawMethodsLib, 'cfg')
                error('ProcessingContext:NoMethodsLoaded', ...
                    'No raw methods library loaded. Use fromGlobals() or loadMethods().');
            end

            if ~ismember(methodName, obj.rawMethodsLib.cfg.Sections)
                error('ProcessingContext:InvalidMethod', ...
                    'Raw method ''%s'' not found. Available: %s', ...
                    methodName, strjoin(obj.rawMethodsLib.cfg.Sections, ', '));
            end

            obj.rawMethodName = methodName;
            obj.rawMethod = pf2_base.pf2_unpackMethod(obj.rawMethodsLib.cfg.(methodName));
            obj.rawMethod.name = methodName;
        end

        function setOxyMethod(obj, methodName)
            % SETOXYMETHOD Set the oxy processing method by name
            %
            % Syntax:
            %   ctx.setOxyMethod('takizawa_easy')
            %
            % The method must exist in oxyMethodsLib.

            if isempty(obj.oxyMethodsLib) || ~isfield(obj.oxyMethodsLib, 'cfg')
                error('ProcessingContext:NoMethodsLoaded', ...
                    'No oxy methods library loaded. Use fromGlobals() or loadMethods().');
            end

            if ~ismember(methodName, obj.oxyMethodsLib.cfg.Sections)
                error('ProcessingContext:InvalidMethod', ...
                    'Oxy method ''%s'' not found. Available: %s', ...
                    methodName, strjoin(obj.oxyMethodsLib.cfg.Sections, ', '));
            end

            obj.oxyMethodName = methodName;
            obj.oxyMethod = pf2_base.pf2_unpackMethod(obj.oxyMethodsLib.cfg.(methodName));
            obj.oxyMethod.name = methodName;
        end

        function loadMethods(obj)
            % LOADMETHODS Populate the raw/oxy method libraries on this context
            %
            % Loads the device method-definition libraries (from the toolbox
            % cfg files, via resolveMethodsLib) into rawMethodsLib/oxyMethodsLib
            % so that setRawMethod/setOxyMethod work on a context that was NOT
            % built through fromGlobals(). Any method NAMES already set on the
            % context (e.g. restored by fromStruct) are re-resolved into their
            % unpacked method structs against the freshly loaded libraries.
            %
            % Syntax:
            %   ctx.loadMethods()
            %
            % See also: pf2_base.resolveMethodsLib, setRawMethod, setOxyMethod

            obj.rawMethodsLib = pf2_base.resolveMethodsLib('raw');
            obj.oxyMethodsLib = pf2_base.resolveMethodsLib('oxy');

            % Re-resolve any names that were set before the library existed.
            if ~isempty(obj.rawMethodName) && ~strcmpi(obj.rawMethodName, 'None')
                obj.setRawMethod(obj.rawMethodName);
            end
            if ~isempty(obj.oxyMethodName) && ~strcmpi(obj.oxyMethodName, 'None')
                obj.setOxyMethod(obj.oxyMethodName);
            end
        end

        % copy() returns an independent instance of the concrete class. It
        % constructs that class with COPY_TOKEN, which subclass constructors
        % must accept and use to skip expensive setup (loading method
        % libraries, reading globals), then copies every public property.
        % Subclasses that keep state in non-public properties must copy it
        % themselves. This is what per-worker / per-subject configuration
        % needs, since plain assignment (ctx2 = ctx) only aliases the handle:
        %
        %   parfor i = 1:N
        %       c = baseCtx.copy();
        %       c.subjectAge = ages(i);
        %       out{i} = processFNIRS2(data{i}, 'Context', c);
        %   end

        function c = copy(obj)
            % COPY Independent shallow copy of the context
            %
            % Returns a new context of the same class with every property
            % copied (handle-valued contents are shared, as with
            % matlab.mixin.Copyable). Use one copy per parfor iteration;
            % plain assignment aliases the same handle.
            %
            % Syntax:
            %   c = ctx.copy();

            if isempty(obj)
                c = obj;
                return;
            end
            props = properties(obj(1));
            props = props(~strcmp(props, 'COPY_TOKEN'));
            for n = numel(obj):-1:1
                c(n) = feval(class(obj(n)), pf2_base.ProcessingContext.COPY_TOKEN);
                for k = 1:numel(props)
                    c(n).(props{k}) = obj(n).(props{k});
                end
            end
            c = reshape(c, size(obj));
        end

        function obj = set.dpfMode(obj, v)
            v = pf2_base.ProcessingContext.asCharRow(v);
            mustBeMember(v, {'None', 'Fixed', 'Calc', 'PPF'});
            obj.dpfMode = v;
        end

        function obj = set.dpfFixedValue(obj, v)
            v = pf2_base.ProcessingContext.asScalarDouble(v);
            mustBePositive(v);
            obj.dpfFixedValue = v;
        end

        function obj = set.subjectAge(obj, v)
            v = pf2_base.ProcessingContext.asScalarDouble(v);
            mustBePositive(v);
            obj.subjectAge = v;
        end

        function obj = set.ppf(obj, v)
            obj.ppf = pf2_base.ProcessingContext.asDoubleRow(v);
        end

        function obj = set.baselineStartTime(obj, v)
            obj.baselineStartTime = pf2_base.ProcessingContext.asScalarDouble(v);
        end

        function obj = set.baselineLength(obj, v)
            v = pf2_base.ProcessingContext.asScalarDouble(v);
            mustBeNonnegative(v);
            obj.baselineLength = v;
        end

        function obj = set.useAbsoluteTime(obj, v)
            obj.useAbsoluteTime = pf2_base.ProcessingContext.asScalarLogical(v);
        end

        function obj = set.windowStartTime(obj, v)
            obj.windowStartTime = pf2_base.ProcessingContext.asScalarDouble(v);
        end

        function obj = set.dirtyBaseline(obj, v)
            obj.dirtyBaseline = pf2_base.ProcessingContext.asScalarLogical(v);
        end

        function obj = set.rawMethodName(obj, v)
            obj.rawMethodName = pf2_base.ProcessingContext.asCharRow(v);
        end

        function obj = set.rawMethod(obj, v)
            obj.rawMethod = pf2_base.ProcessingContext.asStruct(v);
        end

        function obj = set.oxyMethodName(obj, v)
            obj.oxyMethodName = pf2_base.ProcessingContext.asCharRow(v);
        end

        function obj = set.oxyMethod(obj, v)
            obj.oxyMethod = pf2_base.ProcessingContext.asStruct(v);
        end

        function obj = set.rawMethodsLib(obj, v)
            obj.rawMethodsLib = pf2_base.ProcessingContext.asStruct(v);
        end

        function obj = set.oxyMethodsLib(obj, v)
            obj.oxyMethodsLib = pf2_base.ProcessingContext.asStruct(v);
        end

        function obj = set.device(obj, v)
            obj.device = pf2_base.ProcessingContext.asStruct(v);
        end

        function obj = set.rejectLevel(obj, v)
            v = pf2_base.ProcessingContext.asScalarDouble(v);
            pf2_base.ProcessingContext.mustBeInRange(v, 0, 1);
            obj.rejectLevel = v;
        end

        function obj = set.processRejected(obj, v)
            obj.processRejected = pf2_base.ProcessingContext.asScalarLogical(v);
        end

        function obj = set.outputLegacyMarkers(obj, v)
            obj.outputLegacyMarkers = pf2_base.ProcessingContext.asScalarLogical(v);
        end

        function obj = set.rootPath(obj, v)
            obj.rootPath = pf2_base.ProcessingContext.asCharRow(v);
        end

        function s = toStruct(obj)
            % TOSTRUCT Convert context to a plain struct for saving
            %
            % Syntax:
            %   s = ctx.toStruct();
            %   save('settings.mat', '-struct', 's');

            s = struct();
            s.contextVersion = '1.0';
            s.created = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
            s.dpfMode = obj.dpfMode;
            s.dpfFixedValue = obj.dpfFixedValue;
            s.pvc = obj.pvc;
            s.ppf = obj.ppf;
            s.subjectAge = obj.subjectAge;
            s.baselineStartTime = obj.baselineStartTime;
            s.baselineLength = obj.baselineLength;
            s.useAbsoluteTime = obj.useAbsoluteTime;
            s.windowStartTime = obj.windowStartTime;
            s.dirtyBaseline = obj.dirtyBaseline;
            s.rawMethodName = obj.rawMethodName;
            s.oxyMethodName = obj.oxyMethodName;
            s.rejectLevel = obj.rejectLevel;
            s.processRejected = obj.processRejected;
            s.outputLegacyMarkers = obj.outputLegacyMarkers;
            s.rootPath = obj.rootPath;
        end
    end

    methods (Static)
        function obj = fromGlobals()
            % FROMGLOBALS Create a ProcessingContext from current global state
            %
            % Reads PF2 and setF globals and creates a context with matching
            % settings. This is useful for:
            %   - Creating an isolated copy for parallel processing
            %   - Saving current settings for reproducibility
            %   - Starting from current settings and modifying
            %
            % Syntax:
            %   ctx = ProcessingContext.fromGlobals();
            %
            % Example:
            %   % Save current settings
            %   ctx = ProcessingContext.fromGlobals();
            %   save('my_settings.mat', 'ctx');
            %
            %   % Modify for parallel processing. Snapshot once here in the
            %   % client, then copy() per worker (fromGlobals on a worker sees
            %   % empty globals; plain assignment would alias one handle).
            %   baseCtx = ProcessingContext.fromGlobals();
            %   parfor i = 1:N
            %       ctx = baseCtx.copy();
            %       ctx.subjectAge = ages(i);
            %       results{i} = processFNIRS2(data{i}, 'Context', ctx);
            %   end

            global PF2 setF

            % Ensure globals are initialized
            if ~isfield(PF2, 'myRawMethods') || ~isfield(PF2, 'baseline')
                pf2_base.pf2_initialize();
            end

            obj = pf2_base.ProcessingContext();

            % DPF settings
            if isfield(PF2, 'dpf_mode')
                obj.dpfMode = PF2.dpf_mode;
            end
            if isfield(PF2, 'curDPF_fixed')
                obj.dpfFixedValue = PF2.curDPF_fixed;
            end
            if isfield(PF2, 'curDPF_age')
                obj.subjectAge = PF2.curDPF_age;
            end
            if isfield(PF2, 'pvc')
                obj.pvc = PF2.pvc;
            end
            if isfield(PF2, 'ppf')
                obj.ppf = PF2.ppf;
            end

            % Baseline settings
            if isfield(PF2, 'baseline')
                if isfield(PF2.baseline, 'startTime')
                    obj.baselineStartTime = PF2.baseline.startTime;
                end
                if isfield(PF2.baseline, 'blLength')
                    obj.baselineLength = PF2.baseline.blLength;
                end
                if isfield(PF2.baseline, 'useAbsoluteTime')
                    obj.useAbsoluteTime = PF2.baseline.useAbsoluteTime;
                end
                if isfield(PF2.baseline, 'windowStartTime')
                    obj.windowStartTime = PF2.baseline.windowStartTime;
                end
            end

            % Quality control
            if isfield(PF2, 'RejectLevel')
                obj.rejectLevel = PF2.RejectLevel;
            end

            % Output options
            if isfield(PF2, 'OutputLegacyMarkers')
                obj.outputLegacyMarkers = PF2.OutputLegacyMarkers;
            end

            % Method libraries
            if isfield(PF2, 'myRawMethods')
                obj.rawMethodsLib = PF2.myRawMethods;
            end
            if isfield(PF2, 'myOxyMethods')
                obj.oxyMethodsLib = PF2.myOxyMethods;
            end

            % Current methods
            if isfield(PF2, 'stageRawMethod')
                obj.rawMethod = PF2.stageRawMethod;
                if isfield(PF2.stageRawMethod, 'name')
                    obj.rawMethodName = PF2.stageRawMethod.name;
                end
            end
            if isfield(PF2, 'stageOxyMethod')
                obj.oxyMethod = PF2.stageOxyMethod;
                if isfield(PF2.stageOxyMethod, 'name')
                    obj.oxyMethodName = PF2.stageOxyMethod.name;
                end
            end

            % Paths
            if isfield(PF2, 'defaultRootPath')
                obj.rootPath = PF2.defaultRootPath;
            end

            % Device configuration
            if isstruct(setF) && isfield(setF, 'device')
                obj.device = setF.device;
            end
        end

        function obj = fromStruct(s)
            % FROMSTRUCT Create a ProcessingContext from a saved struct
            %
            % Syntax:
            %   s = load('settings.mat');
            %   ctx = ProcessingContext.fromStruct(s);

            obj = pf2_base.ProcessingContext();

            if isfield(s, 'dpfMode'), obj.dpfMode = s.dpfMode; end
            if isfield(s, 'dpfFixedValue'), obj.dpfFixedValue = s.dpfFixedValue; end
            if isfield(s, 'pvc'), obj.pvc = s.pvc; end
            if isfield(s, 'ppf'), obj.ppf = s.ppf; end
            if isfield(s, 'subjectAge'), obj.subjectAge = s.subjectAge; end
            if isfield(s, 'baselineStartTime'), obj.baselineStartTime = s.baselineStartTime; end
            if isfield(s, 'baselineLength'), obj.baselineLength = s.baselineLength; end
            if isfield(s, 'useAbsoluteTime'), obj.useAbsoluteTime = s.useAbsoluteTime; end
            if isfield(s, 'windowStartTime'), obj.windowStartTime = s.windowStartTime; end
            if isfield(s, 'dirtyBaseline'), obj.dirtyBaseline = s.dirtyBaseline; end
            if isfield(s, 'rawMethodName'), obj.rawMethodName = s.rawMethodName; end
            if isfield(s, 'oxyMethodName'), obj.oxyMethodName = s.oxyMethodName; end
            if isfield(s, 'rejectLevel'), obj.rejectLevel = s.rejectLevel; end
            if isfield(s, 'processRejected'), obj.processRejected = s.processRejected; end
            if isfield(s, 'outputLegacyMarkers'), obj.outputLegacyMarkers = s.outputLegacyMarkers; end
            if isfield(s, 'rootPath'), obj.rootPath = s.rootPath; end

            % Reload the method libraries so a deserialized recipe is actually
            % usable: without this, rawMethodsLib/oxyMethodsLib stay empty and
            % the restored method names cannot be resolved (setRawMethod would
            % error). loadMethods() also re-resolves the names into structs.
            obj.loadMethods();
        end
    end

    methods (Static, Access = private)
        % The helpers below follow the order MATLAB applies to a typed
        % property declaration: convert to the declared class, then check
        % or reshape to the declared size, then run validators. Conversion
        % failures raise MATLAB:validation:UnableToConvert and size
        % failures MATLAB:validation:IncompatibleSize, as the declarations
        % did.

        function v = asCharRow(v)
            % As a '(1,:) char' declaration.
            v = pf2_base.ProcessingContext.convertTo(v, @char);
            v = pf2_base.ProcessingContext.asRow(v);
        end

        function v = asScalarDouble(v)
            % As a '(1,1) double' declaration.
            v = pf2_base.ProcessingContext.convertTo(v, @double);
            pf2_base.ProcessingContext.requireScalar(v);
        end

        function v = asDoubleRow(v)
            % As a '(1,:) double' declaration.
            v = pf2_base.ProcessingContext.convertTo(v, @double);
            v = pf2_base.ProcessingContext.asRow(v);
        end

        function v = asScalarLogical(v)
            % As a '(1,1) logical' declaration.
            v = pf2_base.ProcessingContext.convertTo(v, @logical);
            pf2_base.ProcessingContext.requireScalar(v);
        end

        function v = asStruct(v)
            % As a 'struct' declaration: structs pass through, and an
            % empty numeric, char or logical array becomes a field-less
            % struct array of the same size.
            if isstruct(v)
                return;
            end
            if isempty(v) && (isnumeric(v) || ischar(v) || islogical(v))
                v = repmat(struct(), size(v));
                return;
            end
            error('MATLAB:validation:UnableToConvert', ...
                'Value must be a struct.');
        end

        function v = convertTo(v, convertFcn)
            % Apply a class conversion, reporting failure as MATLAB does.
            try
                v = convertFcn(v);
            catch
                error('MATLAB:validation:UnableToConvert', ...
                    'Value must be convertible to %s.', func2str(convertFcn));
            end
        end

        function v = asRow(v)
            % Reshape to a row when at most one dimension is non-singleton
            % (including N-D arrays such as 1x1x3) or the input is 0x0, as
            % a '(1,:)' size declaration does; reject anything else.
            if sum(size(v) ~= 1) <= 1 || isequal(size(v), [0 0])
                v = reshape(v, 1, []);
            else
                error('MATLAB:validation:IncompatibleSize', ...
                    'Value must be a 1-by-N vector.');
            end
        end

        function requireScalar(v)
            % Reject non-scalars, as a '(1,1)' size declaration does.
            if ~isscalar(v)
                error('MATLAB:validation:IncompatibleSize', ...
                    'Value must be a scalar.');
            end
        end

        function mustBeInRange(value, minVal, maxVal)
            % Range validator for rejectLevel.
            if value < minVal || value > maxVal
                error('MATLAB:validators:mustBeInRange', ...
                    'Value must be between %g and %g', minVal, maxVal);
            end
        end
    end
end
