function [HbO, HbR, Total, HbDiff,CBSI,channels,time,units,DPF_factor]=bvoxy(varargin)
% BVOXY Convert optical density to hemoglobin concentrations via Beer-Lambert law
%
% Applies the modified Beer-Lambert law (MBLL) to convert optical density
% changes at two wavelengths into changes in oxygenated (HbO) and
% deoxygenated (HbR) hemoglobin concentrations. This is the core Stage 2
% transformation in the fNIRS processing pipeline.
%
% The Beer-Lambert law relates optical density changes to chromophore
% concentration changes:
%   delta_OD = epsilon * delta_C * d * DPF
%
% Where:
%   epsilon = molar extinction coefficient (wavelength-dependent)
%   delta_C = concentration change
%   d       = source-detector distance
%   DPF     = differential pathlength factor (accounts for scattering)
%
% References:
%   Modified Beer-Lambert Law:
%     Delpy, D. T. et al. (1988). Estimation of optical pathlength through
%     tissue from direct time of flight measurement. Phys. Med. Biol. 33(12).
%
%   DPF Calculation:
%     Scholkmann, F. & Wolf, M. (2013). General equation for the differential
%     pathlength factor of the frontal human head depending on wavelength
%     and age. J. Biomed. Opt. 18(10), 105004. DOI: 10.1117/1.JBO.18.10.105004
%
%   Partial-volume correction (PVC) / cortical sensitivity:
%     Strangman, G. E., Zhang, Q., & Li, Z. (2014). Scalp and skull influence
%     on near infrared photon propagation in the Colin27 brain template.
%     NeuroImage, 85, 136-149. DOI: 10.1016/j.neuroimage.2013.04.090
%     Strangman, G., Franceschini, M. A., & Boas, D. A. (2003). Factors
%     affecting the accuracy of near-infrared spectroscopy concentration
%     calculations for focal changes in oxygenation parameters. NeuroImage,
%     18(4), 865-879. DOI: 10.1016/s1053-8119(03)00021-1
%     Boas, D. A. et al. (2001). The accuracy of near infrared spectroscopy
%     and imaging during focal changes in cerebral hemodynamics. NeuroImage,
%     13(1), 76-90. DOI: 10.1006/nimg.2000.0674
%     Hiraoka, M. et al. (1993). A Monte Carlo investigation of optical
%     pathlength in inhomogeneous tissue and its application to near-infrared
%     spectroscopy. Phys. Med. Biol. 38(12), 1859-1876.
%     DOI: 10.1088/0031-9155/38/12/011
%     Uludag, K. et al. (2002). Cross talk in the Lambert-Beer calculation for
%     near-infrared wavelengths estimated by Monte Carlo simulations.
%     J. Biomed. Opt. 7(1), 51. DOI: 10.1117/1.1427048
%
%   Extinction Coefficients:
%     Prahl, S. A. Tabulated molar extinction coefficient for hemoglobin.
%     http://omlc.org/spectra/hemoglobin/
%
% Syntax:
%   fNIR = bvoxy(data, channels, wavelengths, distanceSrcDet)
%   fNIR = bvoxy(data, channels, wavelengths, distanceSrcDet, baselineSamples)
%   fNIR = bvoxy(..., age)
%   fNIR = bvoxy(..., 'DiffPathlengthFactor', dpf)
%   fNIR = bvoxy(..., 'PartialPathlengthFactor', ppf)
%   fNIR = bvoxy(..., 'NoPathlength', true)
%   fNIR = bvoxy(..., 'isOD', true)
%   [HbO, HbR, Total, HbDiff, CBSI, ch, t, units, DPF] = bvoxy(...)
%
% Inputs:
%   data            - Raw light intensity or optical density [T x C_raw]
%                     T = time samples, C_raw = all raw channels (2 per optode)
%   channels        - Channel numbers for each column [1 x C_raw]
%                     Optode number (>0), time (0), or marker (<0)
%   wavelengths     - Wavelength in nm for each column [1 x C_raw]
%                     Typically ~730nm and ~850nm for two-wavelength systems
%   distanceSrcDet  - Source-detector separation in cm [1 x N_optodes]
%                     Typically 2.5-3 cm for standard fNIRS
%   baselineSamples - Sample indices for baseline calculation (default: 1:50)
%                     Baseline mean is subtracted before conversion.
%   age             - Subject age in years for DPF calculation (default: 25)
%                     Used only when DPF mode is 'Calc' (age-dependent).
%
% Name-Value Parameters:
%   There are two mutually exclusive ways to set the pathlength factor:
%   (a) a DPF (fixed or age-calculated) optionally divided by a partial-volume
%   correction PVC, or (b) a complete effective factor supplied directly (PPF).
%   Path (a) is the documented primary route because DPF and PVC each have a
%   checkable range, so typos are caught; (b) is an escape hatch (see PPF).
%
%   'DiffPathlengthFactor' - Fixed DPF value to use (bypasses the age
%                            calculation). Typical adult head-tissue DPF is
%                            ~3-10 (van der Zee 1992: 5.93); a value outside
%                            that range emits a pf2_base:fnirs:bvoxy:dpfRange
%                            warning. Combined with 'PartialVolumeCorrection':
%                            L = distanceSrcDet .* DPF ./ PVC.
%   'PartialVolumeCorrection' - Partial-volume correction divisor (PVC >= 1),
%                            applied to the fixed OR age-calculated DPF:
%                            L = distanceSrcDet .* DPF ./ PVC. A scalar applies
%                            uniformly; a per-optode vector (one value per
%                            optode, in the sorted-optode order of
%                            distanceSrcDet) gives each channel its own
%                            separation/region-specific correction. Default 1
%                            (no correction; the classic "apparent" concentration).
%                            PVC is the total-photon-path / gray-matter-partial-
%                            path ratio, i.e. the reciprocal of the sensitivity
%                            PPL_GM/TPL. It is separation- and region-dependent:
%                            at a conventional 30 mm channel PVC ~ 10 (Strangman,
%                            Zhang & Li 2014, sensitivity ~0.10); it falls
%                            toward ~5 at 50 mm and rises toward ~15+ at 20 mm.
%                            Compute a principled, separation/region-specific
%                            value with pf2_base.fnirs.strangmanPVC rather than
%                            guessing. A hard floor at 1 is enforced (a partial
%                            path cannot exceed the total).
%   'PartialPathlengthFactor' - ESCAPE HATCH: a COMPLETE effective pathlength
%                            factor supplied directly, L = distanceSrcDet .* ppf,
%                            with NO DPF and NO PVC. Use this when you already
%                            have an effective factor from a Monte Carlo or
%                            atlas computation (which yields a partial pathlength
%                            directly, with no DPF/PVC split to recover). It is
%                            deliberately NOT the primary path: a bare factor is
%                            unvalidatable (6 is a fine uncorrected factor and
%                            0.12 a fine corrected one, two orders of magnitude
%                            apart, both plausible), which is precisely the
%                            ambiguity that produces cross-toolbox magnitude
%                            confusion. Scalar (both wavelengths) or [ppf1 ppf2]
%                            wavelength-ascending (sub-805 nm first); every
%                            element must be finite, real, and positive -- a
%                            length-3+ vector, or a NaN/Inf/non-positive value,
%                            errors with pf2_base:fnirs:bvoxy:badPPF rather than
%                            silently truncating or propagating (a bare factor
%                            already can't be range-checked, so malformed input
%                            must be caught outright). Output units uM. Mutually
%                            exclusive with DiffPathlengthFactor /
%                            PartialVolumeCorrection. In this mode the DPF/PVC
%                            components are recorded as unknown (NaN) in the
%                            output rather than back-solved.
%   'NoPathlength'         - If true, skip DPF correction (default: false)
%                            Output units become mM*mm instead of uM.
%   'coefs'                - Custom extinction coefficients [N_wv x 3]
%                            Format: [wavelength, eHbO, eHbR]
%   'isOD'                 - If true, input is already optical density
%                            (default: false, assumes raw intensity)
%
% Outputs:
%   HbO        - Oxygenated hemoglobin changes [T x N_optodes]
%   HbR        - Deoxygenated hemoglobin changes [T x N_optodes]
%   Total      - Total hemoglobin: HbO + HbR [T x N_optodes]
%   HbDiff     - Differential: HbO - HbR [T x N_optodes]
%   CBSI       - Correlation-based signal improvement [T x N_optodes]
%                CBSI = (HbO - alpha*HbR) / 2, where alpha = std(HbO)/std(HbR)
%   channels   - Channel numbers for output columns [1 x N_optodes]
%   time       - Time vector extracted from input [T x 1]
%   units      - Output concentration units: 'uM' or 'mM*mm'
%   DPF_factor - DPF value(s) used in conversion
%
% Algorithm:
%   1. Separate channels by wavelength (< 805nm and > 805nm)
%   2. Calculate baseline mean for each channel
%   3. Convert intensity to optical density: OD = -log10(I / I_baseline)
%   4. Compute DPF from age or use fixed value
%   5. Apply Beer-Lambert law to solve for HbO and HbR
%   6. Calculate derived metrics (Total, Diff, CBSI)
%
% Example:
%   % Basic usage with sample data
%   data = pf2.import.sampleData.fNIR2000();
%   [HbO, HbR] = bvoxy(data.raw, data.info.header.channels, ...
%       data.info.header.wavelengths, data.info.header.SD);
%
%   % With age-dependent DPF for 30-year-old subject
%   fNIR = bvoxy(data.raw, channels, wavelengths, SD, 1:100, 30);
%
%   % With fixed DPF
%   fNIR = bvoxy(data.raw, channels, wavelengths, SD, ...
%       'DiffPathlengthFactor', 5.93);
%
% Notes:
%   - Returns struct when called with single output argument
%   - Currently supports two-wavelength systems only
%   - Marker columns are preserved in output (appended with -1 channel IDs)
%   - distanceSrcDet is expected in centimeters. If its mean exceeds ~10 a
%     pf2_base:fnirs:bvoxy:distanceUnits warning fires (likely millimeters,
%     which yields HbO/HbR ~10x too small); the conversion still proceeds.
%   - PVC definition and wavelength dependence. PVC = TPL / PPL_GM, the ratio
%     of total photon pathlength to gray-matter partial pathlength (the inverse
%     of the sensitivity PPL_GM/TPL). Which denominator is meant matters: the
%     Strangman 2014 sensitivity used here is the path in ALL gray matter the
%     channel samples (giving PVC ~10 at 30 mm); the focal partial-volume-error
%     literature (Strangman 2003, Boas 2001) uses only the FOCALLY ACTIVATED
%     patch, a smaller denominator that yields a larger PVC (~20-60). Same
%     physics, different denominators. This function applies PVC as a single
%     scalar (the quasi-anatomical stance): the DPF is divided uniformly, which
%     assumes the partial-volume factor is wavelength-independent. That is a
%     convenience, not a result -- PPL_GM's wavelength dependence differs from
%     bulk DPF, and that difference is the mechanism of HbO/HbR crosstalk
%     (Uludag 2002). It is negligible for standard two-chromophore cortical
%     activation but matters for broadband NIRS fitting cytochrome-c-oxidase.
%     PVC/sensitivity is also strongly separation- and region-dependent
%     (Strangman 2014, Table 2/3/4): use pf2_base.fnirs.strangmanPVC to get a
%     separation- and location-specific value, and for full rigor prefer
%     Monte Carlo / image reconstruction (pf2.probe.forward.sensitivity,
%     pf2.probe.dot.reconstruct).
%
% See also: processStageRaw2OD, processStageFilterHb, pf2_Intensity2OD,
%           processFNIRS2

p = inputParser;
validScalarPosNum = @(x) isnumeric(x) && isscalar(x) && (x > 0);
validScalarNum = @(x) isnumeric(x) && isscalar(x);
validDataInput = @(x) (isnumeric(x) && ismatrix(x));

addRequired(p,'data',validDataInput);  %Raw data containing light intensity or optical density
addRequired(p,'channels',validDataInput); %Channel numbers corresponding to each column in data
addRequired(p,'wavelengths',validDataInput); %wavelengths for each column in data
addRequired(p,'distanceSrcDet',validDataInput); %source detector distance for each column in channels (in cm)
addOptional(p,'baselineSamples',[1:50],validDataInput); %array of samples to get from baseline (in seconds
addOptional(p,'age',25,validScalarPosNum); %Age to calculate DPF from (in years)
addOptional(p,'coefs',[],validDataInput); %If empty calculate instead of using mfg coefficients
addOptional(p,'isOD',false,@islogical); %Indicates that data is in light intensity instead of OD
addParameter(p,'DiffPathlengthFactor',[],validScalarNum); % Fixed DPF (typical 3-10); overrides the age calculation
addParameter(p,'PartialVolumeCorrection',[],@(x) isempty(x)||(isnumeric(x)&&isvector(x))); % Partial-volume correction divisor(s) (>=1), scalar or per-optode: L = SD.*DPF./pvc
addParameter(p,'PartialPathlengthFactor',[],@(x) isempty(x)||(isnumeric(x)&&isvector(x))); % ESCAPE HATCH: a complete effective factor, L = SD.*ppf (no DPF/PVC decomposition)
addParameter(p,'NoPathlength',false,@islogical); % Force same fixed path length to use (typical is 5.93)
%addOptional(p,'dirtyBaseline',false,@islogical); %get first non-NA value to use as baseline if nothing is readily apparent;

parse(p,varargin{:});

data=p.Results.data; %in units of light intensity
channels=p.Results.channels;
wavelengths=p.Results.wavelengths; %in nm
sd_distance=p.Results.distanceSrcDet(:); %in cm; force a column so it aligns element-wise with the per-optode DPF and any per-optode PVC (a row input would otherwise outer-product)
subject_age=p.Results.age;
baselineSamples=p.Results.baselineSamples;
DiffPathlengthFactor=p.Results.DiffPathlengthFactor; %fixed DPF
pvc=p.Results.PartialVolumeCorrection; %partial-volume correction divisor (>=1)
ppf=p.Results.PartialPathlengthFactor; %complete effective factor (escape hatch)
coefs=p.Results.coefs;
isOD=p.Results.isOD;
NoPathlength=p.Results.NoPathlength;

% Two ways to specify the pathlength factor, kept mutually exclusive:
%   dpf/pvc  -> build an effective factor (DPF/PVC); each is range-checkable
%               (DPF ~3-10, PVC >=1), so typos are caught.
%   ppf      -> a COMPLETE effective factor supplied directly (Monte Carlo /
%               atlas), unvalidatable by construction (6 and 0.12 are both
%               legitimate). This ambiguity is why it is an explicit escape
%               hatch rather than the primary path.
hasDPF = ~isempty(DiffPathlengthFactor) && DiffPathlengthFactor > 0;
if ~isempty(ppf) && (hasDPF || ~isempty(pvc))
    error('pf2_base:fnirs:bvoxy:ppfConflict', ...
        ['Give PartialPathlengthFactor (a complete effective factor), or ' ...
         'DiffPathlengthFactor/PartialVolumeCorrection, not both.']);
end
if ~isempty(ppf) && any(ppf(:) <= 0)
    error('pf2_base:fnirs:bvoxy:ppfPositive', ...
        'PartialPathlengthFactor must be positive; got min %g.', min(ppf(:)));
end
if ~isempty(pvc) && (~isnumeric(pvc) || ~isreal(pvc) || ~all(isfinite(pvc(:))))
    error('pf2_base:fnirs:bvoxy:pvcInvalid', ...
        'PartialVolumeCorrection must be finite real values (no NaN/Inf).');
end
if ~isempty(pvc) && any(pvc(:) < 1)
    error('pf2_base:fnirs:bvoxy:pvcFloor', ...
        ['PartialVolumeCorrection must be >= 1 (it divides the DPF; a partial ' ...
         'path cannot exceed the total). Got min %g. A typical cortical PVC at ' ...
         'a 30 mm channel is ~10 (Strangman 2014).'], min(pvc(:)));
end
if hasDPF && (DiffPathlengthFactor < 3 || DiffPathlengthFactor > 10)
    warning('pf2_base:fnirs:bvoxy:dpfRange', ...
        ['DiffPathlengthFactor=%g is outside the usual head-tissue DPF range ' ...
         '(~3-10). If this is an already-partial-volume-corrected factor, pass ' ...
         'it as PartialPathlengthFactor (the escape hatch) instead.'], ...
        DiffPathlengthFactor);
end
% pvcVal (scalar or per-optode column) is resolved just before the dispatch,
% once the optode count is known.

% Unit-safety guard: source-detector distances are expected in centimeters.
% A mean well above any plausible fNIRS separation (long channels are ~2.5-4.5
% cm, short channels smaller) almost always means millimeters were passed,
% which makes HbO/HbR ~10x too small with no other symptom. Warn loudly but do
% not error (some tomographic montages carry longer separations).
mSD = mean(sd_distance(:), 'omitnan');
if ~NoPathlength && ~isempty(sd_distance) && isfinite(mSD) && mSD > 10
    warning('pf2_base:fnirs:bvoxy:distanceUnits', ...
        ['distanceSrcDet mean=%.1f looks like millimeters, not centimeters ' ...
         '(a typical long channel is ~2.7 cm). HbO/HbR will be ~10x too small. ' ...
         'Pass source-detector distances in cm.'], mSD);
end


if(length(baselineSamples)==1)
    baselineSamples=1:baselineSamples;
end

validChannels=(channels>0.&wavelengths>0);
rawData=data(:,validChannels);      %non-timechannels have >0 channel numbers, markers and others have - indexes
wavelengths=wavelengths(validChannels); %dark channels have 0 wavelength
timeIndex=find(channels==0);  % Added to left at end if exists
len=size(data,1);
mrkIndex=find(channels<0); %Added to right at end if exists
channels=channels(validChannels);

time=data(:,timeIndex);

[uOpt,~,~]=unique(channels);

numOpt=length(uOpt);

numWv=sum(channels==channels(1));

rawArray=nan(len,numOpt,numWv);
wvArray=nan(numOpt,numWv);
chArray=nan(numOpt,numWv+1);

if(numWv>2)
    error('pf2_base:fnirs:bvoxy:multiWavelengthUnsupported', 'MultiWavelengths are not supported yet');
end

wv700=wavelengths<805; %Split so wavelength under isobestic point is first column

%Should be fast but only supports two wavelengths

chArray(:,1)=channels(wv700); % channel number
chArray(:,2)=find(wv700); %raw index of wv700
chArray(:,3)=find(~wv700); %raw index of wv850

chArray(:,4)=wavelengths(chArray(:,2));
chArray(:,5)=wavelengths(chArray(:,3));

[~,b]=sort(chArray(:,1));
chArray=chArray(b,:);

wvArray=chArray(:,[4,5]);

for i=1:numWv
    rawArray(:,:,i)=rawData(:,chArray(:,i+1));
end


[eHbRArray,eHbOArray]=estimateAbsorb(wvArray,coefs);




%bStart=1; %default values from Hitachi system
%bEnd=100;
%sStart=bEnd+1;
%len=size(w700,1)-sStart+1;

% Baseline and the extinction arrays are constant across time, so keep them as
% [1 x numOpt x numWv] and let implicit expansion broadcast them against the
% [len x numOpt x numWv] data. This avoids materializing full-length copies
% (measured: ~2x faster and ~half the peak memory vs repmat), byte-identical.
Baseline=nanmean(rawArray(baselineSamples,:,:),1);

eHbOArray=reshape(eHbOArray,[1,numOpt,numWv]);
eHbRArray=reshape(eHbRArray,[1,numOpt,numWv]);

if(~isOD)
    OD=real(-log10(rawArray./Baseline));
else
    OD=real(rawArray-Baseline);
end


HbO=zeros(len,numOpt);
HbR=zeros(len,numOpt);

if(numWv~=2)
    error('pf2_base:fnirs:bvoxy:unsupportedWavelengthCount', 'Sorry I don''t support this yet');
end

%Note w1~700nm w2~830nm
%While these frequencies are listed here they are generic 700 is
%effectively wv1 and 830 is effectively wv2
%Channels are sorted by wavelength so <805 should be first and >805
%should be second

od700=OD(:,:,1);
od830=OD(:,:,2);

% Resolve PVC to a scalar or a per-optode column aligned to the sorted optode
% order (same order as sd_distance / DPF_700). A per-optode vector lets each
% channel carry its own separation/region-specific correction.
if isempty(pvc)
    pvcVal = 1;
elseif isscalar(pvc)
    pvcVal = pvc;
elseif numel(pvc) == numOpt
    pvcVal = pvc(:);
else
    error('pf2_base:fnirs:bvoxy:pvcLength', ...
        ['PartialVolumeCorrection must be a scalar or have one value per ' ...
         'optode (%d); got %d.'], numOpt, numel(pvc));
end

if(NoPathlength)
    %Convert to mM*mm from uM*cm

    L_700=100;
    L_830=100;

    DPF_factor=[nan,nan];
    pathInfo=struct('mode','none','dpf',[nan nan],'pvc',nan,'effective',[nan nan]);

    units='mM*mm';

elseif(~isempty(ppf))
    % Escape hatch: ppf is a COMPLETE effective pathlength factor supplied
    % directly (e.g. a Monte Carlo / atlas partial pathlength), so
    % L = SD .* ppf with NO DPF and NO PVC to recover. The DPF/PVC components
    % are recorded as unknown (NaN) rather than back-solving a split that was
    % never provided. A scalar ppf applies to both wavelengths; a vector must
    % be exactly [ppf1 ppf2] wavelength-ascending (channels are sorted <805 nm
    % first). Every element must be finite, real, and positive: silently
    % truncating a longer vector to its first two elements (a stray third
    % value from e.g. a copy-paste error) or accepting a NaN/Inf would corrupt
    % HbO/HbR without any other symptom, so both are rejected outright.
    if ~(isnumeric(ppf) && isreal(ppf) && all(isfinite(ppf(:))) && all(ppf(:) > 0) ...
            && (isscalar(ppf) || numel(ppf) == 2))
        error('pf2_base:fnirs:bvoxy:badPPF', ...
            ['PartialPathlengthFactor must be a scalar or exactly two finite, ' ...
             'real, positive values [ppf1 ppf2] (one per wavelength); got %s.'], ...
            mat2str(ppf));
    end

    if(isscalar(ppf))
        ppfVec=[ppf ppf];
    else
        ppfVec=ppf(1:2);
    end

    L_700=sd_distance.*ppfVec(1);
    L_830=sd_distance.*ppfVec(2);

    DPF_factor=ppfVec;
    pathInfo=struct('mode','ppf','dpf',[nan nan],'pvc',nan,'effective',ppfVec);

    units='uM';

elseif(hasDPF)
    % Fixed DPF, optionally partial-volume corrected: L = SD .* DPF ./ PVC.
    % ./ broadcasts a per-optode pvcVal column against the [nOpt x 1] distances.
    L_700=sd_distance.*(DiffPathlengthFactor./pvcVal);
    L_830=sd_distance.*(DiffPathlengthFactor./pvcVal);

    pvcSummary=mean(pvcVal(:));
    DPF_factor=DiffPathlengthFactor./pvcSummary;
    pathInfo=struct('mode','fixed','dpf',[DiffPathlengthFactor DiffPathlengthFactor], ...
        'pvc',pvcSummary,'effective',[DiffPathlengthFactor DiffPathlengthFactor]./pvcSummary);

    units='uM';
else
    % Age/wavelength DPF (Scholkmann & Wolf 2013), optionally partial-volume
    % corrected: L = SD .* DPF_calc ./ PVC. The Scholkmann DPF is valid for the
    % frontal cortex; used everywhere until a better solution is available.
    DPF_700=scholkmannDPF(wvArray(:,1),subject_age);
    DPF_830=scholkmannDPF(wvArray(:,2),subject_age);

    L_700=sd_distance.*(DPF_700./pvcVal);
    L_830=sd_distance.*(DPF_830./pvcVal);

    pvcSummary=mean(pvcVal(:));
    DPF_factor=unique([DPF_700, DPF_830]./pvcVal);
    pathInfo=struct('mode','calc','dpf',[mean(DPF_700) mean(DPF_830)],'pvc',pvcSummary, ...
        'effective',[mean(DPF_700) mean(DPF_830)]./pvcSummary);

    units='uM';
end

eHBO_700=eHbOArray(:,:,1);
eHBR_700=eHbRArray(:,:,1);
eHBO_830=eHbOArray(:,:,2);
eHBR_830=eHbRArray(:,:,2);

% eHBO_700=reshape(eHBO_700,[numOpt,len]);
% eHBR_700=reshape(eHBR_700,[numOpt,len]);
% eHBO_830=reshape(eHBO_830,[numOpt,len]);
% eHBR_830=reshape(eHBR_830,[numOpt,len]);
% 
% od700=reshape(od700,[numOpt,len]);
% od830=reshape(od830,[numOpt,len]);

% Keep L as [1 x numOpt] rows and broadcast against the [len x numOpt] OD; no
% repmat to full length (measured ~2x, half memory), byte-identical.
L_700=L_700(:).';
L_830=L_830(:).';

HbO=(eHBR_830.*(od700./L_700)-eHBR_700.*(od830./L_830))./(eHBO_700.*eHBR_830-eHBO_830.*eHBR_700);
HbR=(eHBO_700.*(od830./L_830)-eHBO_830.*(od700./L_700))./(eHBO_700.*eHBR_830-eHBO_830.*eHBR_700);

%HbO= reshape(HbO,[numOpt,len])';
%HbR= reshape(HbR,[numOpt,len])';

%Oxy(:,ch)=(OD(1,:,ch)*eHBR_830-OD_830(:,ch)*eHBR_700)/(eHBO_700*eHBR_830-eHBO_830*eHBR_700)/DiffPathlengthFactor;
%Deoxy(:,ch)=(OD_830(:,ch)*eHBO_700-OD_700(:,ch)*eHBO_830)/(eHBO_700*eHBR_830-eHBO_830*eHBR_700)/DiffPathlengthFactor;



%add index and marker information

Total=[(HbO+HbR), data(:,mrkIndex)];
HbDiff=[(HbO-HbR), data(:,mrkIndex)];
CBSI=[calcCBSI(HbO,HbR), data(:,mrkIndex)];
HbO=[(HbO), data(:,mrkIndex)];
HbR=[(HbR), data(:,mrkIndex)];

channels=[uOpt,(mrkIndex*0-1)];

if(nargout==1) % if one output argument, return all as fNIR struct
	fNIR.HbO=HbO;
	fNIR.HbR=HbR;
	fNIR.HbDiff=HbDiff;
	fNIR.CBSI=CBSI;
	fNIR.HbTotal=Total;
	fNIR.time=time;
	fNIR.channels=channels;
	fNIR.DPF_factor=DPF_factor;
	fNIR.pathlengthInfo=pathInfo; % provenance: mode + dpf/pvc/effective (NaN if unknown)
	fNIR.units=units;

	HbO=fNIR; %return only the struct
	return;
end

end

function dpf=scholkmannDPF(lambda,Age)
% SCHOLKMANNDPF Age- and wavelength-dependent differential pathlength factor
%
% General equation for the DPF of the frontal human head (Scholkmann & Wolf,
% 2013, J. Biomed. Opt. 18(10) 105004. DOI: 10.1117/1.JBO.18.10.105004).
%
% Inputs:
%   lambda - Wavelength(s) in nm
%   Age    - Subject age in years
%
% Outputs:
%   dpf    - Differential pathlength factor (dimensionless), same size as lambda

alpha=223.3;
beta=0.05624;
gamma=0.8493;
delta=-5.723e-7;
eta=0.001245;
sigma=-0.9025;
dpf = alpha + beta*Age.^gamma + delta*lambda.^3 + eta.*lambda.^2 + sigma*lambda;

end

function [eHbR,eHbO]=estimateAbsorb(lambda,coefs)
% coeficients should be in 1/(cm*microMolar)
% but are output in millimolar (1/(cm*uM))
%
% Note: previously memoized with a containers.Map keyed by mat2str(lambda).
% Measured on R2025b, the mat2str key-hashing costs more than the two interp1
% calls it avoids (~7-15x SLOWER at typical montage sizes), so the cache was
% removed and the coefficients are computed directly.

%Sourced Data from http://omlc.org/spectra/hemoglobin/summary.html
% molar extinction coefficient
% Wavelength (nm), HbO, (1/(cm*M)), HbR(1/(cm*M))
    altCoeff=[650,	368,	3750.12; ...
    652,	356.8,	3642.64; ...
    654,	345.6,	3535.16; ...
    656,	335.2,	3427.68; ...
    658,	325.6,	3320.2; ...
    660,	319.6,	3226.56; ...
    662,	314,	3140.28; ...
    664,	308.4,	3053.96; ...
    666,	302.8,	2967.68; ...
    668,	298,	2881.4; ...
    670,	294,	2795.12; ...
    672,	290,	2708.84; ...
    674,	285.6,	2627.64; ...
    676,	282,	2554.4; ...
    678,	279.2,	2481.16; ...
    680,	277.6,	2407.92; ...
    682,	276,	2334.68; ...
    684,	274.4,	2261.48; ...
    686,	272.8,	2188.24; ...
    688,	274.4,	2115; ...
    690,	276,	2051.96; ...
    692,	277.6,	2000.48; ...
    694,	279.2,	1949.04; ...
    696,	282,	1897.56; ...
    698,	286,	1846.08; ...
    700,	290,	1794.28; ...
    702,	294,	1741; ...
    704,	298,	1687.76; ...
    706,	302.8,	1634.48; ...
    708,	308.4,	1583.52; ...
    710,	314,	1540.48; ...
    712,	319.6,	1497.4; ...
    714,	325.2,	1454.36; ...
    716,	332,	1411.32; ...
    718,	340,	1368.28; ...
    720,	348,	1325.88; ...
    722,	356,	1285.16; ...
    724,	364,	1244.44; ...
    726,	372.4,	1203.68; ...
    728,	381.2,	1152.8; ...
    730,	390,	1102.2; ...
    732,	398.8,	1102.2; ...
    734,	407.6,	1102.2; ...
    736,	418.8,	1101.76; ...
    738,	432.4,	1100.48; ...
    740,	446,	1115.88; ...
    742,	459.6,	1161.64; ...
    744,	473.2,	1207.4; ...
    746,	487.6,	1266.04; ...
    748,	502.8,	1333.24; ...
    750,	518,	1405.24; ...
    752,	533.2,	1515.32; ...
    754,	548.4,	1541.76; ...
    756,	562,	1560.48; ...
    758,	574,	1560.48; ...
    760,	586,	1548.52; ...
    762,	598,	1508.44; ...
    764,	610,	1459.56; ...
    766,	622.8,	1410.52; ...
    768,	636.4,	1361.32; ...
    770,	650,	1311.88; ...
    772,	663.6,	1262.44; ...
    774,	677.2,	1213; ...
    776,	689.2,	1163.56; ...
    778,	699.6,	1114.8; ...
    780,	710,	1075.44; ...
    782,	720.4,	1036.08; ...
    784,	730.8,	996.72; ...
    786,	740,	957.36; ...
    788,	748,	921.8; ...
    790,	756,	890.8; ...
    792,	764,	859.8; ...
    794,	772,	828.8; ...
    796,	786.4,	802.96; ...
    798,	807.2,	782.36; ...
    800,	816,	761.72; ...
    802,	828,	743.84; ...
    804,	836,	737.08; ...
    806,	844,	730.28; ...
    808,	856,	723.52; ...
    810,	864,	717.08; ...
    812,	872,	711.84; ...
    814,	880,	706.6; ...
    816,	887.2,	701.32; ...
    818,	901.6,	696.08; ...
    820,	916,	693.76; ...
    822,	930.4,	693.6; ...
    824,	944.8,	693.48; ...
    826,	956.4,	693.32; ...
    828,	965.2,	693.2; ...
    830,	974,	693.04; ...
    832,	982.8,	692.92; ...
    834,	991.6,	692.76; ...
    836,	1001.2,	692.64; ...
    838,	1011.6,	692.48; ...
    840,	1022,	692.36; ...
    842,	1032.4,	692.2; ...
    844,	1042.8,	691.96; ...
    846,	1050,	691.76; ...
    848,	1054,	691.52; ...
    850,	1058,	691.32; ...
    852,	1062,	691.08; ...
    854,	1066,	690.88; ...
    856,	1072.8,	690.64; ...
    858,	1082.4,	692.44; ...
    860,	1092,	694.32; ...
    862,	1101.6,	696.2; ...
    864,	1111.2,	698.04; ...
    866,	1118.4,	699.92; ...
    868,	1123.2,	701.8; ...
    870,	1128,	705.84; ...
    872,	1132.8,	709.96; ...
    874,	1137.6,	714.08; ...
    876,	1142.8,	718.2; ...
    878,	1148.4,	722.32; ...
    880,	1154,	726.44; ...
    882,	1159.6,	729.84; ...
    884,	1165.2,	733.2; ...
    886,	1170,	736.6; ...
    888,	1174,	739.96; ...
    890,	1178,	743.6; ...
    892,	1182,	747.24; ...
    894,	1186,	750.88; ...
    896,	1190,	754.52; ...
    898,	1194,	758.16; ...
    900,	1198,	761.84];

altCoeff(:,[2,3])=altCoeff(:,[2,3])*1e-3; % convert from eta to absorption coefficint mu_a 
    %by multiplying by molar concentration and 2.303 (ln(10)) and convert to
    %micromolar (mM)
    
    


if(nargin<2||isempty(coefs)) % AutoCalulate With
    coefs=altCoeff;
end

%fNIR Devices saturation coefficietns
      coeff_fd=[730,0.390,1.1022;...
          805, 0.836, 0.73708;...
          850, 1.058,0.69132;];
      %eHbR_730=1.1022; % [1/(mMol*cm)
      %eHBO_730=0.390;      %
      %eHBR_805=0.73708;      %   saturation coefficients
      %eHBO_805=0.836;      %
      %eHBR_850=0.69132;      %
      %eHBO_850=1.058;      %

%Hitachi saturation coefficients

coeffHitachi=[700.8	701.5	702.3	703	703.7   826.4	827.2   827.9	828.7;  %wavelength
    0.42060317	0.42175357	0.42295032	0.42399946	0.4250284 0.99762517	0.99762517 0.99762517	1.00145609; %HBO2 absorption
    1.80362957	1.78824951	1.77265013	1.75866636	1.74526153 0.77802499	0.77802499 0.77802499	0.77798873;]; %HB absorption

%Reverse Engineered values from Hitachi data
% Need to update for 826.4, 827.2



eHbO=interp1(coefs(:,1),coefs(:,2),lambda)./1000;  %convert from 1/mM to 1/uM
eHbR=interp1(coefs(:,1),coefs(:,3),lambda)./1000;   %convert from 1/mM to 1/uM

end

% This script is available for download to academic researchers for
% internal research use only. All commercial use requires a license 
% from Stanford's OTL. Please contact imelda.oropeza@stanford.edu for 
% more details.
%
% -------------------------------------------------------------------
%
% assume the original signal is oxy and deoxy, and the corrected signal is
% oxy0.
%
% Xu Cui
% Stanford University
% 2009/09/28

% offline version (post-experiment data analysis)

function cOxy=calcCBSI(oxy,deoxy)

if(~isempty(oxy)&&size(oxy,1)==size(deoxy,1)&&size(oxy,2)==size(deoxy,2))

    alpha = nanstd(oxy)./nanstd(deoxy);
    oxy0=zeros(size(oxy));
    for i=1:length(alpha)
       oxy0(:,i)=oxy(:,i)-alpha(i)*deoxy(:,i); 
    end
    %oxy0 = oxy - alpha .* deoxy;
    cOxy= oxy0 / 2;

elseif(isempty(oxy))
    cOxy=[];
    warning('CBSI error: Oxy arrays and Deoxy arrays are empty');
else
    error('pf2_base:fnirs:bvoxy:dimensionMismatch', 'Oxy and Deoxy size mismatch');
end
end