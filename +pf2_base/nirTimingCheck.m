function timing = nirTimingCheck(time, varargin)
% NIRTIMINGCHECK Regularity of sample times taken from the PC time column
%
% Files without a device sample counter (COBI Classic, 1200W) are timed by
% the PC time stamp of each sample, and fs is 1/median(diff(time)), which
% assumes uniform sampling. Recordings whose sampling pace was irregular
% (for example 625 to 750 ms steps) break that assumption. This reports how
% many steps differ from the median step by more than a tolerance and warns
% when that fraction is large. A few long steps from dropouts do not raise
% the fraction much and are not warned about.
%
% Syntax:
%   timing = pf2_base.nirTimingCheck(time)
%   timing = pf2_base.nirTimingCheck(time, 'Tolerance', 0.05, 'MaxIrregular', 0.2)
%
% Inputs:
%   time - Sample times in seconds [N x 1 double]
%
% Name-Value Parameters:
%   'Tolerance'    - Relative difference from the median step that counts
%                    as irregular (default: 0.05)
%   'MaxIrregular' - Fraction of irregular steps above which
%                    'pf2:importNIR:irregularTiming' is warned (default: 0.2)
%
% Outputs:
%   timing - Struct:
%              .method            - 'pc'
%              .medianStep        - Median of diff(time) (s)
%              .irregularFraction - Fraction of steps further than
%                                   Tolerance from the median step
%              .stepCV            - Coefficient of variation of the steps
%              .irregular         - irregularFraction > MaxIrregular
%
% See also: pf2.import.importNIR, pf2_base.nirCounterTimebase

p = inputParser;
p.addParameter('Tolerance', 0.05, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('MaxIrregular', 0.2, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.parse(varargin{:});
opts = p.Results;

timing = struct('method', 'pc', 'medianStep', NaN, 'irregularFraction', NaN, ...
    'stepCV', NaN, 'irregular', false);
dt = diff(double(time(:)));
dt = dt(isfinite(dt));
if numel(dt) < 2
    return;
end
m = median(dt);
timing.medianStep = m;
timing.irregularFraction = mean(abs(dt / m - 1) > opts.Tolerance);
timing.stepCV = std(dt) / mean(dt);
timing.irregular = timing.irregularFraction > opts.MaxIrregular;
if timing.irregular
    warning('pf2:importNIR:irregularTiming', ...
        ['Sample times from the PC time column are irregular: %.0f%% of steps differ ' ...
         'from the median step (%.3f s) by more than %.0f%%. fs = 1/median step ' ...
         'assumes uniform sampling; consider resampling to a uniform grid ' ...
         '(pf2.data.resample) before filtering.'], ...
        100 * timing.irregularFraction, m, 100 * opts.Tolerance);
end
end
