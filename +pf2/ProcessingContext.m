classdef ProcessingContext < pf2_base.ProcessingContext
    % PROCESSINGCONTEXT Self-contained processing configuration for pf2
    %
    % A ProcessingContext bundles every setting processFNIRS2 needs -- DPF
    % mode, baseline, methods, device, rejection level -- into one object you
    % configure explicitly and thread through processing, instead of relying on
    % the global PF2/setF state. Passing it to processFNIRS2 (via 'Context')
    % gives isolated, reproducible, parallel-safe processing: the globals are
    % neither read nor written on that path.
    %
    % This is the public, user-facing entry point. Unlike the internal
    % pf2_base.ProcessingContext, a bare pf2.ProcessingContext() is immediately
    % usable -- its constructor loads the method libraries, so setRawMethod /
    % setOxyMethod (and the 'RawMethod'/'OxyMethod' name-value shortcuts) work
    % without first snapshotting globals via fromGlobals().
    %
    % Syntax:
    %   ctx = pf2.ProcessingContext()
    %   ctx = pf2.ProcessingContext(Name, Value, ...)
    %
    % Inputs (Name-Value pairs; all optional):
    %   'RawMethod'    - Name of a raw-stage method (e.g. 'OD_TDDR')
    %   'OxyMethod'    - Name of an oxy-stage method (e.g. 'takizawa_easy')
    %   'DPFmode'      - 'None' | 'Fixed' | 'Calc' | 'PPF'
    %   'FixedDPF'     - Fixed DPF value (used when DPFmode is 'Fixed')
    %   'PVC'          - Partial-volume correction divisor (>=1) applied to the
    %                    Fixed/Calc DPF: L = SD.*DPF./pvc (pf2_base.fnirs.strangmanPVC)
    %   'PPF'          - Complete effective factor (escape hatch), scalar or
    %                    [ppf1 ppf2] (used when DPFmode is 'PPF'; L = SD.*ppf)
    %   'SubjectAge'   - Age in years (used when DPFmode is 'Calc')
    %   'blLength'     - Baseline duration (seconds)
    %   'blStartTime'  - Baseline start (seconds)
    %   'RejectLevel'  - Channel rejection threshold in [0,1)
    %   'DirtyBaseline'- Use the whole signal mean as baseline (logical)
    %   'Device'       - Device configuration struct
    %   Any property name of the class is also accepted directly.
    %
    % Outputs:
    %   ctx - a pf2.ProcessingContext handle object
    %
    % Examples:
    %   % Configure once, in one call, without touching globals
    %   ctx = pf2.ProcessingContext('RawMethod','OD_TDDR', ...
    %       'DPFmode','Calc', 'SubjectAge',25, 'blLength',10);
    %   out = processFNIRS2(data, 'Context', ctx);
    %   % ...or let the context be the receiver:
    %   out = ctx.process(data);
    %
    %   % Parallel, one independent context per worker (note copy(), not '='):
    %   parfor i = 1:numel(allData)
    %       c = ctx.copy();
    %       c.subjectAge = ages(i);
    %       results{i} = processFNIRS2(allData{i}, 'Context', c);
    %   end
    %
    % See also: processFNIRS2, pf2_base.ProcessingContext

    methods
        function obj = ProcessingContext(varargin)
            % PROCESSINGCONTEXT Construct a usable, configured context
            %
            % Loads the method libraries so the object is usable immediately,
            % then applies any Name-Value settings.

            obj@pf2_base.ProcessingContext();
            % copy() constructs with COPY_TOKEN and then overwrites every
            % property, so skip loading the method libraries.
            if nargin == 1 && isequal(varargin{1}, pf2_base.ProcessingContext.COPY_TOKEN)
                return;
            end
            obj.loadMethods();
            if nargin > 0
                obj.configure(varargin{:});
            end
        end

        function obj = configure(obj, varargin)
            % CONFIGURE Apply Name-Value settings to the context (in-place)
            %
            % Accepts the same Name-Value pairs as the constructor. Mutates the
            % context in place (handle semantics) and returns the same handle,
            % so calls may be chained if preferred (re-assignment is optional).
            %
            % Syntax:
            %   ctx.configure('blLength', 5, 'RejectLevel', 0.1)

            if mod(numel(varargin), 2) ~= 0
                error('pf2:ProcessingContext:configure:pairs', ...
                    'Settings must be provided as Name, Value pairs.');
            end
            for i = 1:2:numel(varargin)
                obj.applySetting(varargin{i}, varargin{i+1});
            end
        end

        function varargout = process(obj, data, varargin)
            % PROCESS Run processFNIRS2 on DATA using this context
            %
            % Convenience so the context can be the receiver rather than a
            % keyword argument. Equivalent to
            %   processFNIRS2(data, 'Context', obj, ...)
            %
            % The processFNIRS2 GUI rule applies: capturing the output
            % (out = ctx.process(data)) suppresses the GUI; calling
            % ctx.process(data) with no output routes to the GUI.
            %
            % Syntax:
            %   out = ctx.process(data)
            %   out = ctx.process(data, 'SkipRaw', true)

            [varargout{1:nargout}] = processFNIRS2(data, 'Context', obj, varargin{:});
        end
    end

    methods (Access = private)
        function applySetting(obj, key, val)
            % APPLYSETTING Map one Name-Value pair onto a context property
            %
            % Accepts friendly / processFNIRS2-style aliases as well as exact
            % property names.

            if ~(ischar(key) || (isstring(key) && isscalar(key)))
                error('pf2:ProcessingContext:configure:badKey', ...
                    'Setting names must be character vectors or strings.');
            end
            key = char(key);

            switch lower(key)
                case {'rawmethod', 'rawmethodname'}
                    obj.setRawMethod(char(val));
                case {'oxymethod', 'oxymethodname'}
                    obj.setOxyMethod(char(val));
                case 'dpfmode'
                    obj.dpfMode = char(val);
                case {'fixeddpf', 'dpffixedvalue'}
                    obj.dpfFixedValue = val;
                case {'pvc', 'partialvolumecorrection'}
                    obj.pvc = val;
                case {'ppf', 'partialpathlengthfactor'}
                    obj.ppf = val;
                case {'subjectage', 'defaultsubjectage'}
                    obj.subjectAge = val;
                case {'bllength', 'baselinelength'}
                    obj.baselineLength = val;
                case {'blstarttime', 'baselinestarttime'}
                    obj.baselineStartTime = val;
                case 'rejectlevel'
                    obj.rejectLevel = val;
                case {'dirtybaseline'}
                    obj.dirtyBaseline = logical(val);
                case {'processrejected', 'processrejectedchannels'}
                    obj.processRejected = logical(val);
                case 'device'
                    obj.device = val;
                otherwise
                    if isprop(obj, key)
                        obj.(key) = val;
                    else
                        error('pf2:ProcessingContext:unknownSetting', ...
                            'Unknown setting ''%s''.', key);
                    end
            end
        end
    end

end
