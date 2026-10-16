function [feat, info] = accelFeatures(x, fs, varargin)
% ACCELFEATURES Derive motion features from a multi-axis accelerometer signal
%
% Computes summary motion features from accelerometer/IMU axes: the vector
% magnitude (norm) and its temporal derivative (jerk). These features drive
% accelerometer-informed motion detection and correction, and serve as motion
% nuisance regressors.
%
% Syntax:
%   [feat, info] = pf2.data.aux.accelFeatures(x, fs)
%   [feat, info] = pf2.data.aux.accelFeatures(x, fs, 'Name', Value)
%
% Inputs:
%   x  - Accelerometer data [T x C] (typically C = 3 axes).
%   fs - Sampling rate in Hz [scalar].
%
% Name-Value Parameters:
%   'RemoveGravity' - Subtract the median norm (gravity baseline) so the norm
%                     reflects dynamic acceleration around 0 (default: true).
%
% Outputs:
%   feat - Struct with fields:
%          .norm - [T x 1] vector magnitude sqrt(sum(x.^2, 2))
%                  (gravity-removed if requested).
%          .jerk - [T x 1] magnitude of the time-derivative of the norm
%                  (abs(diff)*fs), same length as norm.
%   info - Struct with: gravity (subtracted baseline), nAxes.
%
% Notes:
%   - With gravity removed, a still subject sits near norm = 0; motion shows as
%     positive deflections. Jerk emphasizes abrupt transients (head movement).
%
% Example:
%   [feat, info] = pf2.data.aux.accelFeatures(proc.Aux.accelerometer.data, 50);
%   motionMask = feat.norm > 3 * mad(feat.norm, 1);
%
% See also: pf2_base.auxSignalType, pf2.data.auxOnGrid

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
x = pf2_base.args.check(x, '', '', {@mustBeNumeric}, 'Invalid argument at position 1.');
fs = pf2_base.args.check(fs, '', '', {@mustBeNumeric, @mustBeScalarOrEmpty, @mustBePositive}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('accelFeatures', varargin, {}, {
    'RemoveGravity', (true), '1,1', 'logical', {}
    });
removeGravity = opts.RemoveGravity;

if isrow(x)
    x = x(:);
end

nrm = sqrt(sum(x.^2, 2));
gravity = 0;
if removeGravity
    gravity = median(nrm, 'omitnan');
    nrm = nrm - gravity;
end

jerk = [0; abs(diff(nrm)) * fs];

feat = struct('norm', nrm, 'jerk', jerk);
info = struct('gravity', gravity, 'nAxes', size(x, 2));

end
