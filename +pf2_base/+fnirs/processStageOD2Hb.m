function outData = processStageOD2Hb(data, time, subjectAge, DirtyBaseline, curProbe, baseline, dpfMode, dpfFixed, defaultAge, varargin)
% PROCESSSTAGEOD2HB Convert optical density to hemoglobin concentrations
%
% Beer-Lambert conversion stage of the fNIRS processing pipeline.
% Converts optical density (OD) data to oxygenated (HbO) and deoxygenated
% (HbR) hemoglobin concentrations using the modified Beer-Lambert law.
%
% Syntax:
%   outData = processStageOD2Hb(data, time, subjectAge, DirtyBaseline, curProbe, baseline, dpfMode, dpfFixed, defaultAge)
%   outData = processStageOD2Hb(..., 'BaselineSamples', samples)
%
% Inputs:
%   data          - [T x C] Optical density data (T=timepoints, C=channels)
%   time          - [T x 1] Time vector in seconds
%   subjectAge    - Subject age in years (can be empty)
%   DirtyBaseline - Logical, if true use entire signal mean as baseline
%   curProbe      - Probe structure with TableCh and TableOpt
%   baseline      - Struct with fields:
%                     startTime - Baseline start time (seconds)
%                     blLength  - Baseline duration (seconds)
%   dpfMode       - DPF mode: 'None', 'Fixed', 'Calc', or 'PPF'
%   dpfFixed      - Fixed DPF value (used when dpfMode is 'Fixed')
%   defaultAge    - Default age for DPF calculation when subjectAge empty
%
% Name-Value Arguments:
%   BaselineSamples - Pre-computed sample indices for baseline. When
%                     provided, overrides the DirtyBaseline and baseline
%                     struct computation. Used by the GUI for view-relative
%                     baseline modes.
%   PPF             - Complete effective pathlength factor (escape hatch) used
%                     when dpfMode is 'PPF': scalar or per-wavelength [ppf1
%                     ppf2]. Pathlength becomes L = SD .* ppf (no DPF/PVC).
%                     Ignored for other modes. (default: [])
%   PVC             - Partial-volume correction divisor (>= 1) applied to the
%                     Fixed/Calc DPF: L = SD .* DPF ./ pvc. Ignored in 'PPF'
%                     and 'None' modes. Compute a value with
%                     pf2_base.fnirs.strangmanPVC. (default: [] -> 1)
%
% Outputs:
%   outData       - Struct containing:
%                     HbO       - [T x N] Oxygenated hemoglobin
%                     HbR       - [T x N] Deoxygenated hemoglobin
%                     HbTotal   - [T x N] Total hemoglobin (HbO + HbR)
%                     HbDiff    - [T x N] Differential (HbO - HbR)
%                     CBSI      - [T x N] Cerebral blood saturation index
%                     channels  - [1 x N] Channel numbers
%                     units     - Unit string (uM or mM*mm)
%                     DPF_factor - DPF value used
%                     time      - Time vector
%
% Example:
%   % Process with 10-second baseline starting at t=0
%   baseline = struct('startTime', 0, 'blLength', 10);
%   outData = pf2_base.fnirs.processStageOD2Hb(odData, time, 25, false, ...
%       curProbe, baseline, 'Calc', 5.93, 25);
%
%   % Process with pre-computed baseline samples (GUI view-relative mode)
%   outData = pf2_base.fnirs.processStageOD2Hb(odData, time, 25, false, ...
%       curProbe, baseline, 'Calc', 5.93, 25, 'BaselineSamples', 1:100);
%
% See also: pf2_base.fnirs.processStageRaw2OD, pf2_base.fnirs.processStageFilterHb, pf2_base.fnirs.bvoxy

% Name-value options. inputParser rather than an arguments block so the
% function also parses under GNU Octave.
ip = inputParser;
ip.FunctionName = 'processStageOD2Hb';
ip.addParameter('BaselineSamples', []);
ip.addParameter('PPF', []);
ip.addParameter('PVC', []);
ip.parse(varargin{:});
options = ip.Results;

% Determine DPF settings. Comparisons are case-insensitive (strcmpi) as
% defense-in-depth: processFNIRS2's validator canonicalizes DPFmode to
% {'None','Fixed','Calc','PPF'} before it reaches here, but this function is
% also callable directly (see BeerLambertPPFTest), so a caller-supplied
% 'ppf'/'calc'/etc. must still select the right branch rather than silently
% falling through to the Calc branch below.
if strcmpi(dpfMode, 'None')
    NoPathlength = true;
else
    NoPathlength = false;
end

if strcmpi(dpfMode, 'Fixed')
    fixedDPF = dpfFixed;
else
    fixedDPF = 0;
end

% PPF (the complete-effective-factor escape hatch) is routed only in 'PPF'
% mode; the partial-volume correction PVC applies to the Fixed/Calc DPF and is
% mutually exclusive with PPF, so it is routed in every other mode.
if strcmpi(dpfMode, 'PPF')
    ppfArg = options.PPF;
    if isempty(ppfArg)
        error('pf2_base:fnirs:processStageOD2Hb:ppfRequired', ...
            ['dpfMode is ''PPF'' but no partial pathlength factor was ' ...
             'supplied. Pass ''PPF'' (scalar or [ppf1 ppf2]).']);
    end
    pvcArg = [];
elseif strcmpi(dpfMode, 'None')
    % 'None' applies no DPF (output stays in mM*mm), so there is no pathlength
    % for PVC to divide; PVC is ignored here (documented). Warn if one was
    % explicitly supplied, and never resolve 'auto' (which would need probe
    % geometry the None path does not require).
    ppfArg = [];
    pvcArg = [];
    if ~isempty(options.PVC)
        warning('pf2_base:fnirs:processStageOD2Hb:pvcIgnoredNone', ...
            'PVC is ignored when dpfMode is ''None'' (no DPF to correct).');
    end
else
    ppfArg = [];
    pvcArg = options.PVC;   % [] unless set; divides the Fixed/Calc DPF
    % 'auto': a per-channel PVC from each channel's own separation (Strangman
    % 2014), so different probe locations get different corrections.
    if ischar(pvcArg) || (isstring(pvcArg) && isscalar(pvcArg))
        if strcmpi(pvcArg, 'auto')
            pvcArg = autoPVCfromProbe(curProbe);
        else
            error('pf2_base:fnirs:processStageOD2Hb:badPVC', ...
                'PVC must be numeric or ''auto''; got ''%s''.', char(pvcArg));
        end
    end
end

if isempty(subjectAge)
    subjectAge = defaultAge;
end

% Determine baseline samples
if ~isempty(options.BaselineSamples)
    % Use pre-computed baseline samples (e.g., GUI view-relative mode)
    baselineSamples = options.BaselineSamples;
elseif DirtyBaseline
    % Use entire signal mean as baseline
    baselineSamples = 1:length(time);
else
    startTime = min(time) + baseline.startTime;
    endTime = startTime + baseline.blLength;

    startSample = find(time >= startTime, 1);
    endSample = find(time >= endTime, 1);
    if isempty(startSample)
        startSample = 1;
    end
    if isempty(endSample)
        endSample = length(time);
    end
    baselineSamples = startSample:endSample;
end

% Get probe tables
curTableOpt = curProbe.TableOpt;
curTableCh = curProbe.TableCh;

% Filter to only channel columns
data = data(:, curTableCh.isCh);
curTableCh = curTableCh(curTableCh.isCh, :);

% Perform Beer-Lambert conversion
[outData.HbO, outData.HbR, outData.HbTotal, outData.HbDiff, outData.CBSI, ...
    outData.channels, ~, outData.units, outData.DPF_factor] = ...
    pf2_base.fnirs.bvoxy(data, curTableCh.OptodeNumber, curTableCh.Wavelength, ...
    curTableOpt.SD, baselineSamples, subjectAge, [], true, ...
    'NoPathlength', NoPathlength, 'DiffPathlengthFactor', fixedDPF, ...
    'PartialPathlengthFactor', ppfArg, 'PartialVolumeCorrection', pvcArg);

outData.time = time;

end

function pvc = autoPVCfromProbe(curProbe)
% AUTOPVCFROMPROBE Per-optode partial-volume correction from separation
%
% Builds a per-optode PVC vector by looking up each channel's own source-
% detector separation in the Strangman 2014 sensitivity model (head-wide),
% so different probe locations receive different corrections. Aligned to the
% TableOpt optode order (the same order bvoxy uses).

if ~isstruct(curProbe) || ~isfield(curProbe, 'TableOpt') || ...
        ~ismember('SD', curProbe.TableOpt.Properties.VariableNames)
    error('pf2_base:fnirs:processStageOD2Hb:autoPVCnoSD', ...
        ['PVC=''auto'' needs source-detector distances (TableOpt.SD). ' ...
         'Supply a numeric PVC or a device with geometry.']);
end

sepMm = curProbe.TableOpt.SD(:) * 10;   % TableOpt.SD is in cm

% Flag optodes whose separation falls outside the Strangman 2014 model range
% (20-50 mm) BEFORE calling strangmanPVC, naming the affected optodes/
% separations. A short-separation channel (e.g. an 8 mm short-channel
% regressor) silently getting clamped to the 20 mm PVC is a correction error,
% not a rounding nuance, so this is surfaced explicitly rather than left to
% strangmanPVC's own generic count-only warning (below, intentionally no
% longer suppressed -- suppressing it previously hid this exact clamping).
outOfRange = sepMm < 20 | sepMm > 50;
if any(outOfRange)
    idx = find(outOfRange);
    if ismember('OptodeNum', curProbe.TableOpt.Properties.VariableNames)
        optLabel = mat2str(curProbe.TableOpt.OptodeNum(idx)');
    else
        optLabel = mat2str(idx');
    end
    warning('pf2_base:fnirs:processStageOD2Hb:pvcExtrapolated', ...
        ['PVC=''auto'': optode(s) %s have separation(s) %s mm outside the ' ...
         'Strangman 2014 model range (20-50 mm) and will be clamped to the ' ...
         'nearest bound before computing PVC. A short-separation channel ' ...
         'clamped to the 20 mm PVC is likely mis-corrected -- supply an ' ...
         'explicit numeric PVC for these channels if this matters.'], ...
        optLabel, mat2str(round(sepMm(idx)', 1)));
end

% One vectorized call for the whole montage (strangmanPVC is separation-vector
% aware); avoids a per-channel inputParser + interp1 loop. strangmanPVC's own
% pf2_base:fnirs:strangmanPVC:extrapolate warning is left enabled (not
% suppressed) as a second, generic line of defense.
pvc = pf2_base.fnirs.strangmanPVC(sepMm);

end
