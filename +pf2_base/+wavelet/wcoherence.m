function result = wcoherence(x, y, fs, varargin)
% WCOHERENCE Wavelet coherence without Wavelet Toolbox
%
% Computes wavelet coherence (WTC) between two time series using the
% Morlet CWT. Can accept pre-computed CWT coefficients to avoid redundant
% computation when called in batch (e.g., for connectivity matrices).
%
% The coherence is defined as:
%   WCoh(f,t) = |S(Wxy)|^2 / (S(|Wxx|^2) * S(|Wyy|^2))
% where S denotes Gaussian smoothing in both time and scale, and
% Wxy = Wx * conj(Wy) is the cross-wavelet spectrum.
%
% Syntax:
%   result = pf2_base.wavelet.wcoherence(x, y, fs)
%   result = pf2_base.wavelet.wcoherence(x, y, fs, 'FreqRange', [0.01 0.1])
%   result = pf2_base.wavelet.wcoherence(x, y, fs, 'CwtX', cwtStructX, 'CwtY', cwtStructY)
%
% Inputs:
%   x  - [T x 1] first time series (column vector)
%   y  - [T x 1] second time series (column vector)
%   fs - Sampling frequency in Hz (positive scalar)
%
% Name-Value Parameters:
%   FreqRange       - [fLow fHigh] frequency band in Hz (default: [0.01, fs/2])
%   VoicesPerOctave - Frequency resolution (default: 10, range 1-48)
%   ApplyCOI        - Exclude cone-of-influence from scalar value (default: true)
%   PhaseOutput     - Return phase angles from cross-spectrum (default: false)
%   CwtX            - Pre-computed CWT struct for x (from pf2_base.wavelet.cwt)
%                     When provided, skips CWT computation for x.
%   CwtY            - Pre-computed CWT struct for y (from pf2_base.wavelet.cwt)
%                     When provided, skips CWT computation for y.
%   SmoothedAutoX   - Pre-computed smoothed |Wx|^2 matrix [F x T] (from batch mode)
%   SmoothedAutoY   - Pre-computed smoothed |Wy|^2 matrix [F x T] (from batch mode)
%   SmoothFactor    - Smoothing kernel width in units of scale (default: 1)
%                     Larger values = more smoothing = smoother coherence.
%   Precision       - 'single' (default) or 'double' for CWT computation.
%
% Outputs:
%   result - Struct with fields:
%     .value     - Mean WCT magnitude in FreqRange (scalar, COI-masked).
%                  NaN when either input has no finite samples or is
%                  constant, or when the supplied CWT coefficients are NaN;
%                  coherence is undefined for those inputs.
%     .pvalue    - NaN (use permutation test for significance)
%     .method    - 'wcoherence'
%     .windowed  - false
%     .wcoh      - [F x T] wavelet coherence matrix (0 to 1)
%     .freqs     - [F x 1] frequency vector (Hz)
%     .times     - [T x 1] time vector (seconds)
%     .coi       - [T x 1] cone of influence boundary (Hz)
%     .freqRange - [fLow fHigh] band used for scalar value
%     .phase     - [F x T] phase angles in radians (if PhaseOutput=true)
%
% Notes:
%   No Wavelet Toolbox required. Uses pf2_base.wavelet.cwt internally.
%   When called from batch connectivity code, pass CwtX/CwtY to avoid
%   redundant CWT computation (the main performance optimization).
%
% References:
%   Grinsted, A., Moore, J.C. & Jevrejeva, S. (2004). Application of the
%   cross wavelet transform and wavelet coherence to geophysical time
%   series. Nonlinear Processes in Geophysics, 11, 561-566.
%
%   Torrence, C. & Compo, G.P. (1998). A practical guide to wavelet
%   analysis. Bulletin of the American Meteorological Society, 79(1),
%   61-78. DOI: 10.1175/1520-0477(1998)079<0061:APGTWA>2.0.CO;2
%
% See also: pf2_base.wavelet.cwt, exploreFNIRS.coupling.wcoherence

    % --- Fast argument parsing (no inputParser) ---
    freqRangeOpt = [];
    vpo = 10;
    applyCOI = true;
    phaseOutput = false;
    cwtXopt = [];
    cwtYopt = [];
    smoothAutoX = [];
    smoothAutoY = [];
    smoothFactor = 1;
    precision = 'single';

    for k = 1:2:length(varargin)
        key = varargin{k};
        val = varargin{k+1};
        switch lower(key)
            case 'freqrange',       freqRangeOpt = val;
            case 'voicesperoctave', vpo = val;
            case 'applycoi',        applyCOI = val;
            case 'phaseoutput',     phaseOutput = val;
            case 'cwtx',            cwtXopt = val;
            case 'cwty',            cwtYopt = val;
            case 'smoothedautox',   smoothAutoX = val;
            case 'smoothedautoy',   smoothAutoY = val;
            case 'smoothfactor',    smoothFactor = val;
            case 'precision',       precision = val;
        end
    end

    x = x(:);
    y = y(:);
    T = length(x);

    % Coherence is undefined for a missing or constant input
    degenerate = isDegenerate(x) || isDegenerate(y);

    % NaN handling: linear interpolation
    x = fillNaN(x);
    y = fillNaN(y);

    % Default frequency range
    if isempty(freqRangeOpt)
        fLow = max(0.01, 1 / (T / fs));
        fHigh = fs / 2;
    else
        fLow = max(freqRangeOpt(1), 1 / (T / fs));
        fHigh = min(freqRangeOpt(2), fs / 2);
    end

    % --- Compute or retrieve CWT ---
    cwtArgs = {'VoicesPerOctave', vpo, 'Precision', precision};

    if ~isempty(cwtXopt)
        Wx = cwtXopt;
    else
        Wx = pf2_base.wavelet.cwt(x, fs, cwtArgs{:});
    end

    if ~isempty(cwtYopt)
        Wy = cwtYopt;
    else
        Wy = pf2_base.wavelet.cwt(y, fs, cwtArgs{:});
    end

    % Extract coefficients
    freqs = Wx.freqs;
    coi = Wx.coi;
    scales = Wx.scales;
    WxCoeffs = Wx.coeffs(:, :, 1);  % [F x T]
    WyCoeffs = Wy.coeffs(:, :, 1);  % [F x T]

    nF = length(freqs);

    % --- Cross-wavelet spectrum ---
    Wxy = WxCoeffs .* conj(WyCoeffs);  % [F x T]

    % --- Smoothing ---
    sWxy = smoothCWT(Wxy, scales, fs, smoothFactor);

    % Use pre-computed smoothed auto-spectra if provided
    if ~isempty(smoothAutoX)
        sWxx = smoothAutoX;
    else
        sWxx = smoothCWT(abs(WxCoeffs).^2, scales, fs, smoothFactor);
    end

    if ~isempty(smoothAutoY)
        sWyy = smoothAutoY;
    else
        sWyy = smoothCWT(abs(WyCoeffs).^2, scales, fs, smoothFactor);
    end

    % --- Wavelet coherence ---
    wcoh = abs(sWxy).^2 ./ (sWxx .* sWyy + eps(class(sWxx)));
    % Clamp rounding overshoot; min(NaN, 1) would return 1 and turn
    % NaN coefficients (e.g. a cached CWT of a missing series) into
    % perfect coherence
    wcoh(wcoh > 1) = 1;
    if degenerate
        wcoh(:) = NaN;
    end

    % --- Build time vector ---
    times = (0:T-1)' / fs;

    % --- Frequency band mask ---
    freqMask = freqs >= fLow & freqs <= fHigh;

    % --- COI mask ---
    coi = coi(:)';
    if applyCOI
        coiMask = bsxfun(@ge, freqs(:), coi);  % freq >= coi(t) -> valid
    else
        coiMask = true(nF, T);
    end

    validMask = bsxfun(@and, freqMask(:), true(1, T)) & coiMask;

    % --- Scalar value ---
    if any(validMask(:))
        result.value = mean(wcoh(validMask), 'omitnan');
    else
        result.value = NaN;
    end

    result.pvalue = NaN;
    result.method = 'wcoherence';
    result.windowed = false;
    result.wcoh = wcoh;
    result.freqs = freqs;
    result.times = times;
    result.coi = coi(:);
    result.freqRange = [fLow, fHigh];

    if phaseOutput
        result.phase = angle(sWxy);
    end
end


function S = smoothCWT(W, scales, fs, smoothFactor)
% Smooth CWT coefficients in time and scale using FFT-based convolution
% Time smoothing: Gaussian with width proportional to wavelet scale
% Scale smoothing: boxcar of width 0.6 octaves (Grinsted et al. 2004)

    [nF, T] = size(W);
    dt = 1 / fs;

    % Use real-valued smoothing for real inputs (auto-spectra)
    isRealW = isreal(W);

    % --- Time smoothing (FFT-based, all scales at once) ---
    % Pad T to power of 2 for efficient FFT
    nfftSmooth = 2^nextpow2(T + max(ceil(3 * smoothFactor * scales / dt)));
    Wf = fft(W, nfftSmooth, 2);  % [nF x nfftSmooth]

    S = zeros(nF, T, 'like', W);
    for fi = 1:nF
        sigma_t = smoothFactor * scales(fi) / dt;
        halfWidth = ceil(3 * sigma_t);
        if halfWidth < 1
            S(fi, :) = W(fi, 1:T);
            continue;
        end
        halfWidth = min(halfWidth, floor(T/2));

        % Build Gaussian kernel in frequency domain
        kernel = zeros(1, nfftSmooth, 'like', real(W(1)));
        kernel(1:halfWidth+1) = exp(-(0:halfWidth).^2 / (2 * sigma_t^2));
        kernel(end-halfWidth+1:end) = kernel(halfWidth+1:-1:2);
        kernel = kernel / sum(kernel);
        kernelF = fft(kernel, nfftSmooth);

        % Convolve via FFT multiply
        smoothed = ifft(Wf(fi, :) .* kernelF, nfftSmooth);
        if isRealW
            S(fi, :) = real(smoothed(1:T));
        else
            S(fi, :) = smoothed(1:T);
        end
    end

    % --- Scale smoothing (boxcar in log2-scale space, 0.6 octaves) ---
    scaleSmooth = 0.6;
    log2scales = log2(scales);
    Sout = S;
    for fi = 1:nF
        mask = abs(log2scales - log2scales(fi)) <= scaleSmooth / 2;
        if sum(mask) > 1
            Sout(fi, :) = mean(S(mask, :), 1);
        end
    end
    S = Sout;
end


function tf = isDegenerate(v)
% True when v has fewer than two finite samples or no variation
    f = v(isfinite(v));
    tf = numel(f) < 2 || max(f) == min(f);
end


function v = fillNaN(v)
% Linear interpolation of NaN values
    nanIdx = isnan(v);
    if ~any(nanIdx), return; end
    if all(nanIdx), v(:) = 0; return; end
    t = (1:length(v))';
    v(nanIdx) = interp1(t(~nanIdx), v(~nanIdx), t(nanIdx), 'linear', 'extrap');
end
