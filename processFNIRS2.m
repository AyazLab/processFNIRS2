function varargout = processFNIRS2(varargin)
% PROCESSFNIRS2 MATLAB code for faster non-GUI pipeline
%      2nd generation preprocessing pipleline for fNIRS datasets
%      Uses device configuration files to allow for more repeatable and 
%      more flexible situations
%
%      Always takes a simple array containing the light intensity data and 
%      will optionally load a specific parameters using the varargin option
%      Specifiying an output will hide the GUI unless 'ShowGUI',true is
%      passed as an argument


% To Do: Add 'add function' to configureMethods   
%        Add support for short separation detectors
%       Test with Hitachi data
%       Add support for multiprobe
%       Add suppport for channel rejection
%       Add support for mean addition (but more flexibly)

% See CHANGELOG.md for version history

global PF2
global setF
%global outputData

% Cell array support: process each element and return cell array of results
if ~isempty(varargin) && iscell(varargin{1})
    cellData = varargin{1};
    extraArgs = varargin(2:end);
    results = cell(size(cellData));

    % Determine if parallel processing is appropriate
    nItems = numel(cellData);
    useParfor = false;
    if nItems > 2
        % Check if user explicitly disabled acceleration
        accelDisabled = false;
        for ai = 1:2:length(extraArgs)-1
            if ischar(extraArgs{ai}) && strcmpi(extraArgs{ai}, 'Accelerate') && ...
                    ischar(extraArgs{ai+1}) && strcmpi(extraArgs{ai+1}, 'none')
                accelDisabled = true;
                break;
            end
        end

        if ~accelDisabled
            [canUse, poolRunning] = pf2_base.accel.canParfor();
            useParfor = canUse && poolRunning;
        end
    end

    if useParfor
        % Snapshot global state for workers
        pf2_base.pf2_initialize();
        ctx = pf2_base.ProcessingContext.fromGlobals();

        % Check if Context is already in extraArgs
        hasContext = false;
        for ai = 1:2:length(extraArgs)-1
            if ischar(extraArgs{ai}) && strcmpi(extraArgs{ai}, 'Context')
                hasContext = true;
                break;
            end
        end
        if ~hasContext
            extraArgs = [extraArgs, {'Context', ctx}];
        end

        parfor ci = 1:nItems
            results{ci} = processFNIRS2(cellData{ci}, extraArgs{:});
        end
    else
        for ci = 1:nItems
            results{ci} = processFNIRS2(cellData{ci}, extraArgs{:});
        end
    end

    if nargout > 0
        varargout{1} = results;
    end
    return;
end

% Check if Context is provided before initializing globals
% This allows Context-based processing to bypass global state entirely
hasContextArg = false;
providedContext = [];
for i = 1:length(varargin)
    if ischar(varargin{i}) && strcmpi(varargin{i}, 'Context') && i < length(varargin)
        providedContext = varargin{i+1};
        hasContextArg = ~isempty(providedContext) && isa(providedContext, 'pf2_base.ProcessingContext');
        break;
    end
end

% Only initialize globals if no Context is provided
% Context-based processing is isolated from global state for parallel/reproducible use
if ~hasContextArg
    pf2_base.pf2_initialize() % Loads methods, sets DPF factors, default age, baseline values
                %Also sets default root path
end
% When a Context is provided, processing is fully isolated: globals PF2/setF
% are NOT initialized or written. All settings, methods, and the device are
% threaded as locals from the context (see useContext branch below).

% Set defaults - use Context values if available, otherwise use globals (or hardcoded defaults)
if hasContextArg
    % Defaults from Context - no global access needed
    defaultRawMethod = providedContext.rawMethodName;
    defaultOxyMethod = providedContext.oxyMethodName;
    defaultBlLength = providedContext.baselineLength;
    defaultBlStartTime = providedContext.baselineStartTime;
    defaultSubjectAge = providedContext.subjectAge;
    defaultFixedDPF = providedContext.dpfFixedValue;
    defaultDPFmode = providedContext.dpfMode;
    defaultPPF = providedContext.ppf;
    defaultPVC = providedContext.pvc;
    defaultRejectLevel = providedContext.rejectLevel;
    % For method validation, use context's method libraries
    if ~isempty(providedContext.rawMethodsLib) && isfield(providedContext.rawMethodsLib, 'cfg')
        rawMethodSections = providedContext.rawMethodsLib.cfg.Sections;
    else
        rawMethodSections = {'None'};
    end
    if ~isempty(providedContext.oxyMethodsLib) && isfield(providedContext.oxyMethodsLib, 'cfg')
        oxyMethodSections = providedContext.oxyMethodsLib.cfg.Sections;
    else
        oxyMethodSections = {'None'};
    end
else
    % Defaults from globals
    if pf2_base.isnestedfield(PF2,'stageRawMethod.name') && sum(strcmp(PF2.myRawMethods.cfg.Sections,PF2.stageRawMethod.name))==1
        defaultRawMethod = PF2.stageRawMethod.name;
    else
        defaultRawMethod = 'None';
    end
    if pf2_base.isnestedfield(PF2,'stageOxyMethod.name') && sum(strcmp(PF2.myOxyMethods.cfg.Sections,PF2.stageOxyMethod.name))==1
        defaultOxyMethod = PF2.stageOxyMethod.name;
    else
        defaultOxyMethod = 'None';
    end
    defaultBlLength = PF2.baseline.blLength;
    defaultBlStartTime = PF2.baseline.startTime;
    defaultSubjectAge = PF2.curDPF_age;
    defaultFixedDPF = PF2.curDPF_fixed;
    defaultDPFmode = PF2.dpf_mode;
    if isfield(PF2, 'ppf'); defaultPPF = PF2.ppf; else; defaultPPF = []; end
    if isfield(PF2, 'pvc'); defaultPVC = PF2.pvc; else; defaultPVC = []; end
    defaultRejectLevel = PF2.RejectLevel;
    rawMethodSections = PF2.myRawMethods.cfg.Sections;
    oxyMethodSections = PF2.myOxyMethods.cfg.Sections;
end

p = inputParser;

validScalarPosNum = @(x) isnumeric(x) && isscalar(x) && (x >= 0);
validScalarNum = @(x) isnumeric(x) && isscalar(x);
validDataInput = @(x) ((isnumeric(x) && ismatrix(x))||(isstruct(x)&&(isfield(x,'raw')||isfield(x,'hbo')||isfield(x,'HbO')||isfield(x,'info'))));
validRawMethod = @(x) ischar(validatestring(x, rawMethodSections));
validOxyMethod = @(x) ischar(validatestring(x, oxyMethodSections));
validDPFmode = @(x) ischar(validatestring(x,{'None','Fixed','Calc','PPF'})); % None uses no DPF factor (units mm*mMol), Fixed uses one DPF for all wavelengths, Calc attempts to calculate wavelength*age dependent changes, PPF uses a partial pathlength factor (L=SD.*ppf, MNE/Homer convention)


addOptional(p,'data',[],validDataInput);
addOptional(p,'Raw_Method',defaultRawMethod,validRawMethod); %Attempt to load specified RawMethod
addOptional(p,'Oxy_Method',defaultOxyMethod,validOxyMethod); %Attempt to load specified OxyMethod
addOptional(p,'blLength',defaultBlLength,validScalarPosNum); %specify realtive baseline relative to blStartTime (in seconds)
addOptional(p,'blStartTime',defaultBlStartTime,validScalarNum); %Specify relative baseline start time (in seconds)
addParameter(p,'defaultSubjectAge',defaultSubjectAge,validScalarPosNum); %Use custom default age for DPF calculations rather than whatever was in the GUI
addParameter(p,'UseDeviceCFG','',@ischar); %Input for file containing device configuration info
addParameter(p,'markers',[],@ismatrix); %specify where markers go
addParameter(p,'OutputLegacyMarkers',false,@islogical); % turn on to output marker array into .markers.data instead of just .markers

addParameter(p,'SkipOxy',false,@islogical); %specifies whether to stop processing of data at Oxy
addParameter(p,'SkipOD',false,@islogical); %specifies whether to stop processinf of data before OD conversion
addParameter(p,'SkipRaw',false,@islogical); %specifies whether to skip the raw data and only process oxy data
addParameter(p,'ProcessRejectedChannels',false,@islogical); %specifies whether to attempt to process rejected channels, if false channels are returned as NA

addParameter(p,'ChannelMask',[],@ismatrix); %logical matrix the size of channel array which determines if channel has been rejected, later stored in fChMask
addParameter(p,'ShowGUI',false,@islogical); % turn true to launch GUI
addParameter(p,'DirtyBaseline',false,@islogical); % turn to use the entire mean as the baseline period
addParameter(p,'FixedDPF',defaultFixedDPF,validScalarPosNum); %set default uniwavelength DPF
addParameter(p,'PPF',defaultPPF,@(x) isempty(x)||(isnumeric(x)&&isvector(x))); %complete effective pathlength factor(s) used when DPFmode is 'PPF' (escape hatch, L=SD.*ppf)
addParameter(p,'PVC',defaultPVC,@(x) isempty(x)||(isnumeric(x)&&isvector(x))||(ischar(x)&&strcmpi(x,'auto'))||(isstring(x)&&isscalar(x))); %partial-volume correction divisor(s) (>=1) or 'auto' (per-channel from separation); applied to the Fixed/Calc DPF (L=SD.*DPF./pvc)
addParameter(p,'DPFmode',defaultDPFmode,validDPFmode); %set role of DPF in mBLL calculations
addParameter(p,'ODShortRegression',false,@(x) islogical(x)||iscell(x)); %OD-space short-channel regression before Beer-Lambert: true for defaults, or a cell of shortChannelRegression Name-Value options
addParameter(p,'RejectLevel',defaultRejectLevel,@(x) isnumeric(x)&&isscalar(x)&&x<1&&x>=0); %set the level at which a channel is rejected (fChMask)
addParameter(p,'Context',[],@(x) isempty(x) || isa(x, 'pf2_base.ProcessingContext')); %optional ProcessingContext for isolated processing


addParameter(p,'ImportOxyMethods','NA',@ischar);  %Path for Oxy methods cfg file to import
addParameter(p,'ImportRawMethods','NA',@ischar);  %Path for Raw methods cfg file to import

parse(p,varargin{:});

% Canonicalize DPFmode to the canonical spelling {'None','Fixed','Calc','PPF'}.
% validDPFmode only checks that validatestring succeeds during parsing; it
% does not rewrite p.Results, so a case-insensitive match (e.g. 'ppf') would
% otherwise be threaded downstream (PF2.dpf_mode / ctxDPF_mode) in its
% original casing. Everything downstream compares dpfMode case-sensitively in
% places, so canonicalize once here rather than relying on every consumer to
% do it.
canonicalDPFmode = validatestring(p.Results.DPFmode, {'None','Fixed','Calc','PPF'});

% Handle ProcessingContext if provided
ctx = p.Results.Context;
useContext = ~isempty(ctx);

outputData.ProcessOxy=~p.Results.SkipOxy;
outputData.ProcessRaw=~p.Results.SkipRaw;
outputData.OutputPreProcessedRaw=p.Results.SkipOD;

if(outputData.OutputPreProcessedRaw)
    outputData.ProcessOxy=false;
    outputData.ProcessRaw=true;
end

outputData.ProcessRejected=p.Results.ProcessRejectedChannels;

% Output-marker format threaded as a local. On the legacy path it is also
% mirrored into the global for backward compatibility; on the context path
% globals are left untouched.
outputLegacyMarkers=p.Results.OutputLegacyMarkers;
if(~useContext)
    PF2.OutputLegacyMarkers=outputLegacyMarkers;
end


data=p.Results.data;

skipCFG=false;
if(~isempty(p.Results.UseDeviceCFG)) % if command argument given
    cfgFilePath=p.Results.UseDeviceCFG; % command argument to load cfg file
elseif(pf2_base.isnestedfield(data,'info.probename')&&~contains(data.info.probename,'Unknown')&&~contains(data.info.probename,'generated')) 
    %try to load the probename cfg file
    cfgFilePath=sprintf('%s.cfg',data.info.probename);
elseif(pf2_base.isnestedfield(data,'info.probename')&&~contains(data.info.probename,'Unknown')&&contains(data.info.probename,'generated')) 
    cfgFilePath=sprintf('%s.cfg',data.info.probename);
    skipCFG=true;
else
    cfgFilePath='';
end

% Don't show GUI if Context is provided (context implies headless processing)
ShowGUI=p.Results.ShowGUI||isempty(varargin)||(nargout==0&&~isempty(data)&&isempty(p.Results.Context));

% --- Noop pass-through for empty / non-processable inputs ------------------
% The pipeline converts raw light intensities (data.raw) into hemoglobin, so a
% device configuration is only meaningful when there are raw intensities to
% convert. When an element carries no .raw there is nothing to process and no
% probe cfg is needed: empty cells, or structs already in biomarker form (e.g.
% from pf2.import.fromTable or a prior processFNIRS2 run). Return these
% untouched instead of demanding a device. Exemptions fall through to the normal
% path: SkipRaw deliberately processes non-raw (oxy-only) data; SkipOD requests
% raw-stage output and so is only meaningful with raw present (left to error
% downstream as before rather than silently nooping). NOTE: this fires only when
% the GUI is suppressed; a bare no-output call processFNIRS2(hbStruct) still
% routes to the GUI per the ShowGUI rule above (capture an output to noop).
hasRawIntensity = isstruct(data) && isfield(data,'raw') && ~isempty(data.raw);

% Config-only invocation (no data, global path): persist the parsed settings to
% the session globals BEFORE the noop early-return below. Without this, a bare
% processFNIRS2('blLength',10) call -- and every pf2.settings.* setter that
% delegates here (baseline, DPF, reject level) -- would have its values silently
% discarded by that return. The scalar defaults were read from the current
% globals at parse time, so writing them when unspecified is a no-op; methods are
% only written when explicitly provided, to avoid a config call clobbering the
% active stage method as a side effect. Mirrors the global-write block on the
% normal processing path.
if(~ShowGUI && ~hasContextArg && isempty(data))
    PF2.baseline.startTime = p.Results.blStartTime;
    PF2.baseline.blLength  = p.Results.blLength;
    PF2.curDPF_fixed       = p.Results.FixedDPF;
    PF2.curDPF_age         = p.Results.defaultSubjectAge;
    PF2.dpf_mode           = canonicalDPFmode;
    PF2.ppf                = p.Results.PPF;
    PF2.pvc                = p.Results.PVC;
    PF2.RejectLevel        = p.Results.RejectLevel;

    if(~any(strcmp('Raw_Method',p.UsingDefaults)) && ...
            pf2_base.isnestedfield(PF2,sprintf('myRawMethods.cfg.%s',p.Results.Raw_Method)))
        PF2.stageRawMethod = pf2_base.pf2_unpackMethod(PF2.myRawMethods.cfg.(p.Results.Raw_Method));
        PF2.stageRawMethod.name = p.Results.Raw_Method;
    end
    if(~any(strcmp('Oxy_Method',p.UsingDefaults)) && ...
            pf2_base.isnestedfield(PF2,sprintf('myOxyMethods.cfg.%s',p.Results.Oxy_Method)))
        PF2.stageOxyMethod = pf2_base.pf2_unpackMethod(PF2.myOxyMethods.cfg.(p.Results.Oxy_Method));
        PF2.stageOxyMethod.name = p.Results.Oxy_Method;
    end
end

if(~ShowGUI && (isempty(data) || ...
        (isstruct(data) && ~hasRawIntensity && ~p.Results.SkipRaw && ~p.Results.SkipOD)))
    if(nargout>0)
        varargout{1}=data;
    end
    return;
end

% Device acquisition. On the context path the device is supplied by the
% context (threaded locally below); the legacy/GUI device-loading logic that
% reads/writes global setF.device is skipped to keep processing isolated.
if(~useContext)
    if(isfield(data,'probeinfo')&&~isempty(data.probeinfo))
        setF.device=data.probeinfo;
    else

        if(isempty(cfgFilePath)||~contains(cfgFilePath,'.cfg'))&&(~ShowGUI&&~isempty(data)) %if nothing, invalid, or no data

            warning('Missing or invalid configuration file path\n')

            disp('No device specified. Please load device configuration');
            pf2_base.loadDeviceCfg();
            if(~isfield(setF,'device'))
                error('No valid devices selected');
            end

        elseif(~isempty(cfgFilePath))

            if(pf2_base.isnestedfield(setF,'device.cfg.Info.CfgName')&&length(setF)==1) % look to see if they match,...

                curProbeName=sprintf('%s.cfg',setF.device.cfg.Info.CfgName);

                if(~strcmp(curProbeName,cfgFilePath)&&~skipCFG) %if they do don't bother loading
                    pf2_base.loadDeviceCfg(cfgFilePath);
                end
            else
                pf2_base.loadDeviceCfg(cfgFilePath);
            end
        end

    end
end


if(ShowGUI)
    if pf2_base.env.isOctave()
        error('pf2:gui:octaveUnsupported', ...
            ['Interactive GUIs require MATLAB. Under Octave, use the ' ...
             'programmatic API, e.g. processed = processFNIRS2(data).']);
    end
    if(any(strcmp(p.UsingDefaults,'ShowGUI')))
       l=length(varargin);
       if(l==0)
           pf2.GUI();
           return;
       elseif(~isempty(data))
           varargin(l+1)={'ShowGUI'};
           varargin(l+2)={true};
       end
    end
    if(nargout)
        varargout{1:nargout}=processFNIRS2_GUI(varargin{:});
    else
        processFNIRS2_GUI(varargin{:});
    end
    return
end

% Apply settings - use context if provided, otherwise use parameters/globals
if useContext
    % Use context settings (isolated from globals)
    ctxBaseline.startTime = ctx.baselineStartTime;
    ctxBaseline.blLength = ctx.baselineLength;
    ctxDPF_fixed = ctx.dpfFixedValue;
    ctxDPF_age = ctx.subjectAge;
    ctxDPF_mode = ctx.dpfMode;
    ctxPPF = ctx.ppf;
    ctxPVC = ctx.pvc;
    ctxRejectLevel = ctx.rejectLevel;

    % Override with explicit parameters if provided
    if ~any(strcmp(p.UsingDefaults, 'blStartTime'))
        ctxBaseline.startTime = p.Results.blStartTime;
    end
    if ~any(strcmp(p.UsingDefaults, 'blLength'))
        ctxBaseline.blLength = p.Results.blLength;
    end
    if ~any(strcmp(p.UsingDefaults, 'FixedDPF'))
        ctxDPF_fixed = p.Results.FixedDPF;
    end
    if ~any(strcmp(p.UsingDefaults, 'defaultSubjectAge'))
        ctxDPF_age = p.Results.defaultSubjectAge;
    end
    if ~any(strcmp(p.UsingDefaults, 'DPFmode'))
        ctxDPF_mode = canonicalDPFmode;
    end
    if ~any(strcmp(p.UsingDefaults, 'PPF'))
        ctxPPF = p.Results.PPF;
    end
    if ~any(strcmp(p.UsingDefaults, 'PVC'))
        ctxPVC = p.Results.PVC;
    end
    if ~any(strcmp(p.UsingDefaults, 'RejectLevel'))
        ctxRejectLevel = p.Results.RejectLevel;
    end

    % Honor the context's processRejected unless the call site set it
    % explicitly (an explicit ProcessRejectedChannels argument wins).
    if any(strcmp(p.UsingDefaults, 'ProcessRejectedChannels'))
        outputData.ProcessRejected = ctx.processRejected;
    end

    outputData.DirtyBaseline = ctx.dirtyBaseline || p.Results.DirtyBaseline || ctxBaseline.blLength == 0;

    % Get methods from context
    if isfield(ctx.rawMethod, 'F') && ~isempty(ctx.rawMethod.F)
        ctxRawMethod = ctx.rawMethod;
    else
        % Fall back to 'None' method - use context's method library
        if ~isempty(ctx.rawMethodsLib) && isfield(ctx.rawMethodsLib, 'cfg') && isfield(ctx.rawMethodsLib.cfg, 'None')
            ctxRawMethod = pf2_base.pf2_unpackMethod(ctx.rawMethodsLib.cfg.None);
        else
            ctxRawMethod = struct('F', {{}}, 'name', 'None');
        end
        ctxRawMethod.name = 'None';
    end

    if isfield(ctx.oxyMethod, 'F') && ~isempty(ctx.oxyMethod.F)
        ctxOxyMethod = ctx.oxyMethod;
    else
        % Fall back to 'None' method - use context's method library
        if ~isempty(ctx.oxyMethodsLib) && isfield(ctx.oxyMethodsLib, 'cfg') && isfield(ctx.oxyMethodsLib.cfg, 'None')
            ctxOxyMethod = pf2_base.pf2_unpackMethod(ctx.oxyMethodsLib.cfg.None);
        else
            ctxOxyMethod = struct('F', {{}}, 'name', 'None');
        end
        ctxOxyMethod.name = 'None';
    end

    % Resolve the device as a local (no global write). Prefer the context's
    % device; if the context carries no usable device, load the cfg locally
    % WITHOUT touching global setF (loadFromGlobal=false so the cached-device
    % branch that assigns setF is bypassed and the parsed probeInfo is simply
    % returned).
    if isstruct(ctx.device) && isfield(ctx.device, 'Probe') && ~isempty(ctx.device.Probe)
        procDevice = ctx.device;
    elseif isfield(data,'probeinfo') && ~isempty(data.probeinfo)
        procDevice = data.probeinfo;
    elseif ~isempty(cfgFilePath) && contains(cfgFilePath,'.cfg')
        procDevice = pf2_base.loadDeviceCfg(cfgFilePath, true, false);
    else
        error('pf2:processFNIRS2:noContextDevice', ...
            ['No device available for context-based processing. Provide a ' ...
             'device on the ProcessingContext, embed probeinfo, or supply a ' ...
             'resolvable probename/UseDeviceCFG.']);
    end
else
    % Original behavior - use globals
    PF2.baseline.startTime=p.Results.blStartTime;
    PF2.baseline.blLength=p.Results.blLength;
    ctxBaseline = PF2.baseline;

    outputData.DirtyBaseline=p.Results.DirtyBaseline||PF2.baseline.blLength==0;


    PF2.curDPF_fixed=p.Results.FixedDPF;
    PF2.curDPF_age=p.Results.defaultSubjectAge;
    PF2.dpf_mode=canonicalDPFmode;
    PF2.ppf=p.Results.PPF;
    PF2.pvc=p.Results.PVC;
    ctxDPF_fixed = PF2.curDPF_fixed;
    ctxDPF_age = PF2.curDPF_age;
    ctxDPF_mode = PF2.dpf_mode;
    ctxPPF = PF2.ppf;
    ctxPVC = PF2.pvc;
    ctxRejectLevel = PF2.RejectLevel;

    % Reproducibility guard: on the legacy (no-Context) path DPFmode falls back
    % to the global PF2.dpf_mode, which a prior GUI session may have changed.
    % Only warn when that inherited value has actually diverged from the
    % ProcessingContext default ('Calc'): a fresh headless session initializes
    % to 'Calc', so the common case stays silent and only a GUI-modified,
    % silently-inherited mode trips the warning (once per session).
    persistent batchGlobalDPFWarned
    if isempty(batchGlobalDPFWarned); batchGlobalDPFWarned = false; end
    if ~batchGlobalDPFWarned && pf2_base.isHeadless() ...
            && any(strcmp(p.UsingDefaults,'DPFmode')) && ~strcmpi(ctxDPF_mode,'Calc')
        warning('pf2:processFNIRS2:batchGlobalDPF', ...
            ['Headless run with no ProcessingContext: DPFmode was inherited ' ...
             'from the global PF2.dpf_mode (=''%s''), which differs from the ' ...
             'default and may have been set by a prior GUI session. For ' ...
             'reproducible batch runs pass an explicit pf2.ProcessingContext ' ...
             '(see docs/MATLAB_CLI.md).'], ctxDPF_mode);
        batchGlobalDPFWarned = true;
    end

    rawMethodStr=p.Results.Raw_Method;
    oxyMethodStr=p.Results.Oxy_Method;

    if(pf2_base.isnestedfield(PF2,sprintf('myRawMethods.cfg.%s',rawMethodStr)))
        if(pf2_base.isnestedfield(PF2,'stageRawMethod.name')&&~strcmpi(PF2.stageRawMethod.name,rawMethodStr))
           fprintf('Setting Raw Method to: %s\n',rawMethodStr);
        end

        PF2.stageRawMethod=pf2_base.pf2_unpackMethod(PF2.myRawMethods.cfg.(rawMethodStr));
        PF2.stageRawMethod.name=rawMethodStr;
    else
        error('Unable to find method named: %s',rawMethodStr);
    end


    if(pf2_base.isnestedfield(PF2,sprintf('myOxyMethods.cfg.%s',oxyMethodStr)))
        if(pf2_base.isnestedfield(PF2,'stageOxyMethod.name')&&~strcmpi(PF2.stageOxyMethod.name,oxyMethodStr))
           fprintf('Setting Oxy Method to: %s\n',oxyMethodStr);
        end

        PF2.stageOxyMethod=pf2_base.pf2_unpackMethod(PF2.myOxyMethods.cfg.(oxyMethodStr));
        PF2.stageOxyMethod.name=oxyMethodStr;
    else
        error('Unable to find method named: %s',oxyMethodStr);
    end

    ctxRawMethod = PF2.stageRawMethod;
    ctxOxyMethod = PF2.stageOxyMethod;

    % Legacy path: the device lives in global setF; mirror it locally so the
    % shared downstream code reads the same threaded variable as the context
    % path. Device acquisition (above) may not have populated setF.device yet
    % (e.g. settings-only calls), so guard the access.
    if isstruct(setF) && isfield(setF, 'device')
        procDevice = setF.device;
    else
        procDevice = struct();
    end
end


cfgRawImportPath=p.Results.ImportRawMethods;
cfgOxyImportPath=p.Results.ImportOxyMethods;

if(~strcmp(cfgRawImportPath,'NA'))
    pf2.methods.raw.importMethods(cfgRawImportPath);
end

if(~strcmp(cfgOxyImportPath,'NA'))
    pf2.methods.oxy.importMethods(cfgOxyImportPath);
end

if(isempty(data)||(isstruct(data)&&isfield(data,'info')&&~isfield(data,'raw')&&~isfield(data,'HbO')))
    disp('No data loaded, initializing settings only');
    if(~isempty(data))
       varargout{1}=data; 
    end
    return;
end

for i=1:5
   fData.stage{i}=[];
end

tempOxyStage=[];

if(ismatrix(data)&&~isstruct(data))
   x=data;
   data=[];
   data.raw=x;
end

[validBioFields,altSpellings]=pf2_base.pf2_getFNIRSbiomFields();
[validFields]=pf2_base.pf2_getFNIRSfields();
   
if(isstruct(data)) %treat as fNIR struct
    if(isfield(data,'mrk'))
        if(isnumeric(data.mrk))
            data.markers=data.mrk;
        elseif(isfield(data.mrk,'data'))
            data.markers=data.mrk.data;
            if(~isfield(data,'info'))
                data.info=[];
            end
            if(isfield(data.mrk,'info'))
               data.info.mrkinfo=data.mrk.info;
            end
            if(isfield(data.mrk,'headers'))
                data.info.mrkheaders=data.mrk.headers;
            end
        end
    end

    if(isfield(data,'markers'))
        data.markers=pf2_base.normalizeMarkers(data.markers);
    end

    
    dataFields=fieldnames(data);  % copy bio marker fields
    for i=1:length(dataFields)
        curField=dataFields{i};
       for j=1:length(validBioFields)
           memberIdx=ismember(altSpellings{j},curField);
           if(any(memberIdx))
                if(strcmpi(validBioFields{j},'raw'))
                    fData.stage{1}=data.(curField);
                else
                    tempOxyStage.(validBioFields{j})=data.(curField);
                end
                break;
           end
       end
    end
    
    for i=1:length(dataFields)  % copy other fields
       curField=dataFields{i};
       memberIdx=ismember(validFields,curField);
       if(any(memberIdx))
            if(strcmpi(validFields{memberIdx},'channels')||...
                    strcmpi(validFields{memberIdx},'units')||...
                    strcmpi(validFields{memberIdx},'DPF_factor'))
                tempOxyStage.(validFields{memberIdx})=data.(curField);
            else
                fData.(validFields{memberIdx})=data.(curField);
            end
       end
    end

    
    if(~isfield(fData,'markers'))
       fData.markers=[]; 
    end
    
    if(~isfield(fData,'info'))
        fData.info=[]; 
    end
    
    if(~isfield(fData,'Aux'))
        fData.Aux=[];
    end
    
    [defaultInfoFields,defaultValues]=pf2_base.pf2_getDefaultInfoFields();
    
    for i=1:length(defaultInfoFields)
        if(~isfield(fData.info,defaultInfoFields{i}))
            fData.info.(defaultInfoFields{i})=defaultValues{i};
        end
    end
    
    if(isfield(data,'ROI')&&isstruct(data.ROI)&&pf2_base.isnestedfield(data,'ROI.info'))
        fData.ROI=data.ROI;
    elseif(isfield(data,'ROI')&&iscell(data.ROI))
        fData.ROI=[];
        fData.ROI.info=data.ROI;
    end
end

if isempty(fData.info.Age) && strcmp(ctxDPF_mode, 'Calc')
    warning('pf2:processFNIRS2:noAge', ...
        'fData.info.Age is empty. DPF calculations will use age=%i. Assign subject age for accurate chromophore calculations.', ctxDPF_age);
end

if(~isempty(p.Results.markers))
    fData.markers=p.Results.markers; %Overwrite markers if specified
end

% Canonical marker representation: always a table
fData.markers=pf2_base.normalizeMarkers(fData.markers);

if(isstruct(tempOxyStage))
    fData.stage{4}=tempOxyStage; %Assign stage3 if exists
end

% Thread the device locally. On the context path (useContext) globals are
% left untouched; on the legacy path procDevice mirrors setF.device and the
% globals are updated as before for backward compatibility.
[fData, procDevice]=updateCurrentDevice_local(fData, procDevice, useContext);

[numDataRows,numDataCols]=size(fData.stage{1});

probeIdx=1;
curProbe=procDevice.Probe{probeIdx};
numDevCols=size(curProbe.TableCh,1);
while(numDataCols~=numDevCols)
    if(numDataCols==numDataRows)
       fData.stage{1}=fData.stage{1}';
       break;
    else
       fprintf('Data size %i x %i: Expected %i columns in loaded device',numDevCols);
       warning('Channel/Device mismatch, please load new configuration file');
       if(useContext)
           % The data's own geometry is authoritative. The context-supplied
           % device does not match the data (e.g. a polluted/snapshotted
           % global device of a different channel count). Re-resolve the
           % device from the data's own cfg non-interactively and WITHOUT
           % touching globals (loadFromGlobal=false). Only error if no
           % matching device can be resolved from the data's cfg at all.
           if(~isempty(cfgFilePath) && contains(cfgFilePath,'.cfg'))
               resolvedDevice=pf2_base.loadDeviceCfg(cfgFilePath, true, false);
               resolvedCols=size(resolvedDevice.Probe{probeIdx}.TableCh,1);
               if(resolvedCols==numDataCols || numDataCols==numDataRows)
                   procDevice=resolvedDevice;
               else
                   error('pf2:processFNIRS2:contextChannelMismatch', ...
                       ['Channel/Device mismatch: data has %d columns but ' ...
                        'neither the supplied ProcessingContext device (%d ' ...
                        'columns) nor the data cfg ''%s'' (%d columns) match.'], ...
                       numDataCols, numDevCols, cfgFilePath, resolvedCols);
               end
           else
               error('pf2:processFNIRS2:contextChannelMismatch', ...
                   ['Channel/Device mismatch with the supplied ' ...
                    'ProcessingContext device (%d columns vs %d data ' ...
                    'columns) and no data cfg available to resolve it.'], ...
                   numDevCols, numDataCols);
           end
       else
           pf2_base.loadDeviceCfg();
           procDevice=setF.device;
       end
    end
    [numDataRows,numDataCols]=size(fData.stage{1});
    curProbe=procDevice.Probe{probeIdx};
    numDevCols=size(curProbe.TableCh,1);

end



varargout={};

if(~isempty(data))

    numOptodes=curProbe.NumOptodes;
    if(~isfield(fData,'fchMask')||(isfield(fData,'fchMask')&&isempty(fData.fchMask)))
        fData.fchMask=true(1,curProbe.NumOptodes);
    else
        if(length(fData.fchMask)~=numOptodes)
            origNumOptodes = unique(curProbe.TableCh.OptodeNumber);
            origNumOptodes=origNumOptodes(origNumOptodes>0);

            if(length(fData.fchMask)==length(origNumOptodes))
                fData.fchMask=fData.fchMask(ismember(origNumOptodes,curProbe.TableOpt.OptodeNum));
            else
                warning('pf2:fchMaskMismatch', ...
                    'Channel mask length (%d) does not match optode count (%d). Resetting to all good.', ...
                    length(fData.fchMask), numOptodes);
                fData.fchMask=true(1,numOptodes);
            end
        end
    end
    channelNumbers=curProbe.TableCh.OptodeNumber;
    wavelengths=curProbe.TableCh.Wavelength;
    curOptTable=curProbe.TableOpt;
    
    
    rawMask=ismember(channelNumbers,curProbe.TableOpt.OptodeNum(reshape(fData.fchMask>ctxRejectLevel|outputData.ProcessRejected,1,numOptodes)));

   %varargout=processFNIRdata(); 
   
   
    fAux=fData.Aux;
    fMarkers=fData.markers;
    

   if(outputData.ProcessRaw)

        [fData.stage{3},fData.stage{2}]=pf2_base.fnirs.processStageRaw2OD(ctxRawMethod,fData.stage{1},fData.fs,fData.time,rawMask,fMarkers,fAux,channelNumbers,wavelengths,curOptTable,data); % Raw data processing

        % Optional OD-space short-channel regression, applied BEFORE Beer-Lambert
        % (Brigadoi & Cooper 2015) so systemic residuals are not amplified by the
        % conversion. Opt-in only: default 'ODShortRegression' is false, leaving
        % the pipeline byte-identical. Hb-space SSR remains available as an oxy
        % method (pf2_SSR) that runs after conversion.
        if ~(islogical(p.Results.ODShortRegression) && isscalar(p.Results.ODShortRegression) && ~p.Results.ODShortRegression)
            if iscell(p.Results.ODShortRegression)
                odSSRopts = p.Results.ODShortRegression;
            else
                odSSRopts = {};
            end
            fData.stage{3} = pf2_base.fnirs.shortChannelRegressionOD(fData.stage{3}, ...
                channelNumbers, wavelengths, curProbe, odSSRopts{:});
        end

        if(outputData.ProcessOxy)
            fData.stage{4}=pf2_base.fnirs.processStageOD2Hb(fData.stage{3},fData.time,fData.info.Age,outputData.DirtyBaseline,curProbe,ctxBaseline,ctxDPF_mode,ctxDPF_fixed,ctxDPF_age,'PPF',ctxPPF,'PVC',ctxPVC); % Beer-Lambert conversion
        end
        if isfield(fData,'ROI') && isstruct(fData.ROI) && isfield(fData.ROI,'info')
            fData.stage{4}.ROI.info=fData.ROI.info; %Regenerate from info
        end
    else
        %fData.stage{2}=fData.stage{1};
        if(~isempty(fData.stage{4})&&~isfield(fData.stage{4},'channels'))
           fData.stage{4}.channels=curProbe.ChannelList;
           warning('No channel information given, assuming all columns indexs correspond with channel numbers');
        end
        if isfield(fData,'ROI') && isstruct(fData.ROI) && isfield(fData.ROI,'info')
            fData.stage{4}.ROI=fData.ROI; % Use All ROI information provided
        end
    end
    if(outputData.ProcessOxy)
        fData.stage{4}.fchMask=fData.fchMask>ctxRejectLevel;
        fData.stage{4}.Aux=fData.Aux;
        fData.stage{4}.markers=fData.markers;
        fData.stage{4}.time=fData.time;

        fData.stage{5}=pf2_base.fnirs.processStageFilterHb(ctxOxyMethod,fData.stage{4},fData.fs,curOptTable,outputData.ProcessRejected); % Oxy data processing
    else
        %fData.stage{5}=fData.stage{4};
    end

end

if(nargout>0)
    fdataFields=fieldnames(fData);
    for i=1:length(fdataFields)
       memberIdx=ismember(validFields,fdataFields{i});
       if(any(memberIdx))
            outfNIR.(validFields{memberIdx})=fData.(fdataFields{i});
       end

    end
    
    
   if(isfield(fData,'stage')&&(size(fData.stage,2)==5))
       if(outputData.ProcessOxy&&~isempty(fData.stage{5}))
           stage5fields=fieldnames(fData.stage{5});
            for i=1:length(stage5fields)
                outfNIR.(stage5fields{i})=fData.stage{5}.(stage5fields{i});
            end
          if(~isempty(fData.stage{1}))
            outfNIR.raw=fData.stage{1};
          end
       elseif(outputData.ProcessRaw&&~outputData.OutputPreProcessedRaw)
          if(~isempty(fData.stage{3}))
              outfNIR.OD=fData.stage{3}; %start with OD
          end
          if(~isempty(fData.stage{1}))
            outfNIR.raw=fData.stage{1};
          end
       elseif(outputData.ProcessRaw)
           if(~isempty(fData.stage{2}))
            outfNIR.rawProcessed=fData.stage{2}; 
           end
          if(~isempty(fData.stage{1}))
            outfNIR.raw=fData.stage{1};
          end
       end
       
       if(isfield(fData,'time'))
           outfNIR.time=fData.time;
       end
       
      if(isfield(fData,'markers')&&~isempty(fData.markers))
           if(outputLegacyMarkers)
               outfNIR.markers=[];
               outfNIR.markers.data=pf2_base.markersToArray(fData.markers);
           else
               outfNIR.markers=pf2_base.normalizeMarkers(fData.markers);
           end
       end
       
       if(isfield(fData,'info'))
           outfNIR.info=fData.info;
       end

       % Store processing context for reproducibility and plot enhancement
       outfNIR.processingInfo = buildProcessingInfo(PF2, setF, ctx);
       % Record the OD-space short-channel-regression choice (a processFNIRS2
       % option, not a ctx/global field), so provenance is complete.
       outfNIR.processingInfo.odShortRegression = ...
           ~(islogical(p.Results.ODShortRegression) && isscalar(p.Results.ODShortRegression) && ~p.Results.ODShortRegression);

       % Attach Device object for self-describing output. procDevice is the
       % locally-threaded device (ctx.device on the context path, setF.device
       % on the legacy path) so no global read is needed here.
       deviceSource = [];
       if isstruct(procDevice) && isfield(procDevice, 'cfg')
           deviceSource = procDevice;
       end
       if ~isempty(deviceSource)
           outfNIR.device = pf2.Device.fromProbeInfo(deviceSource);
       end

       % Ensure probe cfg reference is stored for later reloading
       % Full probeinfo is NOT stored to save memory - loadProbeInfo can reload from cfg
       deviceSource = [];
       if isstruct(procDevice) && isfield(procDevice, 'cfg')
           deviceSource = procDevice;
       end
       if ~isempty(deviceSource) && isfield(deviceSource.cfg, 'File')
           if ~isfield(outfNIR, 'info')
               outfNIR.info = struct();
           end
           if ~isfield(outfNIR.info, 'probename') || isempty(outfNIR.info.probename) || contains(outfNIR.info.probename, 'Unknown')
               % Extract probename from cfg file path (remove .cfg extension)
               [~, probename, ~] = fileparts(deviceSource.cfg.File);
               outfNIR.info.probename = probename;
           end
       end

       if(exist('outfNIR'))
           
           varargout={outfNIR};
       else
          varargout={[]}; 
       end
   else
       varargout={[]};
   end
   
end

% On the context path globals are never mutated, so the global cleanup is
% skipped to keep PF2 byte-identical to its pre-call state.
if(~useContext)
    clearVarsOnClose();
end

end


% processStageOD2Hb moved to pf2_base.fnirs.processStageOD2Hb





% UIWAIT makes processFNIRS2 wait for user response (see UIRESUME)
% uiwait(handles.figure1);
function [fData, device]=updateCurrentDevice_local(fData, device, isolated)
% UPDATECURRENTDEVICE_LOCAL Build merged probe tables and resolve timing.
%
% Threads the device locally. When ISOLATED is true (a ProcessingContext is
% in play) the global PF2/setF caches are NOT written, keeping context-based
% processing free of side effects. On the legacy path (ISOLATED false) the
% device is sourced from / synced with global setF and the PF2 caches are
% updated as before for backward compatibility.

global setF
global PF2

if nargin < 3 || isempty(isolated)
    isolated = false;
end

if ~isolated
    if(length(setF)>1)
        setF=setF(1);
    end

    if(isfield(fData,'probeInfo'))
        setF.device=probeInfo;
    end

    device = setF.device;
end

% Delegate to shared function (pure: reads device, returns merged tables/time)
result = pf2_base.gui.updateCurrentDevice(device, fData);

% Write probe caches to globals only on the legacy path.
if ~isolated
    PF2.curCh = result.curCh;
    PF2.curOpt = result.curOpt;
    PF2.curSD = result.curSD;
    PF2.curChList = result.curChList;
    PF2.timeIndex = result.timeIndex;
    PF2.mergedProbe = result.mergedProbe;
    PF2.curChSet = [];
    PF2.curWvSet = [];
    PF2.curSDSet = [];
    PF2.curProbeInd = [];
end

% Write resolved time/fs back to fData
if ~isempty(result.time)
    fData.time = result.time;
end
if ~isempty(result.sampleTime)
    fData.sampleTime = result.sampleTime;
end
if ~isempty(result.fs)
    fData.fs = result.fs;
end
end


function clearVarsOnClose()

global outputData
global PF2
global setF
fieldsToRemove={'data','curMarkersPlot','curMarkers','curNavMarkers','curNavMarkers','view'};

for i=1:length(fieldsToRemove)
   if(isfield(PF2,fieldsToRemove{i}))
       PF2=rmfield(PF2,fieldsToRemove{i});
   end
end

end


function info = buildProcessingInfo(PF2, setF, ctx)
% BUILDPROCESSINGINFO Create processing info struct for output
%
% Captures the processing settings used so plots can display them
% and analyses can be reproduced.
%
% When ctx (ProcessingContext) is provided, uses context values instead of
% PF2/setF globals for isolated processing.

info = struct();
info.timestamp = datetime('now');

% Use context if provided, otherwise read from globals
if nargin >= 3 && ~isempty(ctx) && isa(ctx, 'pf2_base.ProcessingContext')
    % Read from Context - no global access
    info.dpfMode = ctx.dpfMode;
    info.dpfValue = ctx.dpfFixedValue;
    info.ppf = ctx.ppf;
    info.pvc = ctx.pvc;
    info.subjectAge = ctx.subjectAge;
    info.baselineStart = ctx.baselineStartTime;
    info.baselineLength = ctx.baselineLength;
    info.rejectLevel = ctx.rejectLevel;

    if ~isempty(ctx.rawMethod) && isfield(ctx.rawMethod, 'name')
        info.rawMethod = ctx.rawMethod.name;
    elseif ~isempty(ctx.rawMethodName)
        info.rawMethod = ctx.rawMethodName;
    end
    if ~isempty(ctx.oxyMethod) && isfield(ctx.oxyMethod, 'name')
        info.oxyMethod = ctx.oxyMethod.name;
    elseif ~isempty(ctx.oxyMethodName)
        info.oxyMethod = ctx.oxyMethodName;
    end

    % Device info from context
    if ~isempty(ctx.device) && isfield(ctx.device, 'Info')
        if isfield(ctx.device.Info, 'DeviceName')
            info.deviceName = ctx.device.Info.DeviceName;
        end
        if isfield(ctx.device.Info, 'DefaultSamplingRate')
            info.samplingRate = ctx.device.Info.DefaultSamplingRate;
        end
    end
else
    % Read from globals (PF2/setF)
    % DPF settings
    if isfield(PF2, 'dpf_mode')
        info.dpfMode = PF2.dpf_mode;
    end
    if isfield(PF2, 'curDPF_fixed')
        info.dpfValue = PF2.curDPF_fixed;
    end
    if isfield(PF2, 'ppf')
        info.ppf = PF2.ppf;
    end
    if isfield(PF2, 'pvc')
        info.pvc = PF2.pvc;
    end
    if isfield(PF2, 'curDPF_age')
        info.subjectAge = PF2.curDPF_age;
    end

    % Baseline settings
    if isfield(PF2, 'baseline')
        if isfield(PF2.baseline, 'startTime')
            info.baselineStart = PF2.baseline.startTime;
        end
        if isfield(PF2.baseline, 'blLength')
            info.baselineLength = PF2.baseline.blLength;
        end
    end

    % Processing methods
    if isfield(PF2, 'stageRawMethod') && isfield(PF2.stageRawMethod, 'name')
        info.rawMethod = PF2.stageRawMethod.name;
    end
    if isfield(PF2, 'stageOxyMethod') && isfield(PF2.stageOxyMethod, 'name')
        info.oxyMethod = PF2.stageOxyMethod.name;
    end

    % Device info
    if isstruct(setF) && isfield(setF, 'device') && isfield(setF.device, 'Info')
        if isfield(setF.device.Info, 'DeviceName')
            info.deviceName = setF.device.Info.DeviceName;
        end
        if isfield(setF.device.Info, 'DefaultSamplingRate')
            info.samplingRate = setF.device.Info.DefaultSamplingRate;
        end
    end

    % Quality control
    if isfield(PF2, 'RejectLevel')
        info.rejectLevel = PF2.RejectLevel;
    end
end

end
