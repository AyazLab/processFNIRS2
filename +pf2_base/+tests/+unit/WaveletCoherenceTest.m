classdef WaveletCoherenceTest < matlab.unittest.TestCase
% WAVELETCOHERENCETEST Tests for pf2_base.wavelet.wcoherence
%
% Covers:
%   - bounds: identical signals give coherence near 1, values lie in [0, 1]
%   - missing input: an all-NaN series gives NaN, both when the CWTs are
%     computed internally and when cached CWTs are supplied (the cached
%     coefficients of a NaN series are NaN, and the clamp to 1 previously
%     turned them into perfect coherence)
%   - constant input gives NaN
%   - a series with a short gap stays finite and in range
%
% Example:
%   results = runtests('pf2_base.tests.unit.WaveletCoherenceTest');

    properties
        fs = 2
        n = 1200
        band = [0.009 0.06]
    end

    methods (Test)

        function testIdenticalSignalsNearOne(tc)
            rng(1);
            x = cumsum(randn(tc.n, 1));
            r = pf2_base.wavelet.wcoherence(x, x, tc.fs, 'FreqRange', tc.band);
            tc.verifyGreaterThan(r.value, 0.99);
            tc.verifyLessThanOrEqual(r.value, 1);
        end

        function testValuesWithinUnitInterval(tc)
            rng(2);
            r = pf2_base.wavelet.wcoherence(randn(tc.n, 1), randn(tc.n, 1), tc.fs, ...
                'FreqRange', tc.band);
            w = r.wcoh(isfinite(r.wcoh));
            tc.verifyGreaterThanOrEqual(min(w), 0);
            tc.verifyLessThanOrEqual(max(w), 1);
        end

        function testAllNaNInputGivesNaN(tc)
            rng(3);
            r = pf2_base.wavelet.wcoherence(randn(tc.n, 1), nan(tc.n, 1), tc.fs, ...
                'FreqRange', tc.band);
            tc.verifyTrue(isnan(r.value));
        end

        function testCachedCwtOfNaNSeriesGivesNaN(tc)
            rng(4);
            X = randn(tc.n, 2);
            Y = randn(tc.n, 2);
            Y(:, 2) = NaN;
            args = {'FreqRange', [0.0045 0.12], 'VoicesPerOctave', 8};
            Wx = pf2_base.wavelet.cwt(X, tc.fs, args{:});
            Wy = pf2_base.wavelet.cwt(Y, tc.fs, args{:});
            slice = @(W, c) struct('coeffs', W.coeffs(:, :, c), 'freqs', W.freqs, ...
                'coi', W.coi, 'scales', W.scales);

            rGood = pf2_base.wavelet.wcoherence(X(:, 1), Y(:, 1), tc.fs, ...
                'FreqRange', tc.band, 'CwtX', slice(Wx, 1), 'CwtY', slice(Wy, 1));
            rNaN = pf2_base.wavelet.wcoherence(X(:, 1), Y(:, 2), tc.fs, ...
                'FreqRange', tc.band, 'CwtX', slice(Wx, 1), 'CwtY', slice(Wy, 2));

            tc.verifyTrue(isfinite(rGood.value));
            tc.verifyLessThan(rGood.value, 1);
            tc.verifyTrue(isnan(rNaN.value));
        end

        function testConstantInputGivesNaN(tc)
            rng(5);
            r = pf2_base.wavelet.wcoherence(randn(tc.n, 1), zeros(tc.n, 1), tc.fs, ...
                'FreqRange', tc.band);
            tc.verifyTrue(isnan(r.value));
        end

        function testShortGapStaysFinite(tc)
            rng(6);
            y = randn(tc.n, 1);
            y(100:160) = NaN;
            r = pf2_base.wavelet.wcoherence(randn(tc.n, 1), y, tc.fs, 'FreqRange', tc.band);
            tc.verifyTrue(isfinite(r.value));
            tc.verifyGreaterThanOrEqual(r.value, 0);
            tc.verifyLessThanOrEqual(r.value, 1);
        end

    end
end
