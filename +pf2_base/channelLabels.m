function labels = channelLabels(channels)
% CHANNELLABELS Zero-padded text labels for channel numbers
%
% Builds one label per channel number, zero-padded to the width of the
% largest number ('01', '02', ..., '16'), so labels sort in channel order
% and contain no spaces. Used for channel columns and channel-name fields
% in exported group tables.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   labels = pf2_base.channelLabels(channels)
%
% Inputs:
%   channels - Numeric vector of non-negative integer channel numbers.
%
% Outputs:
%   labels - Column cell array of char labels, one per channel ({} when
%            channels is empty).
%
% Example:
%   pf2_base.channelLabels([1 2 10])   % -> {'01'; '02'; '10'}
%
% See also: exploreFNIRS.export.mergeGbyTablesWide,
%           exploreFNIRS.export.mergeGbyTablesLong

    channels = channels(:);
    if isempty(channels)
        labels = cell(0, 1);
        return;
    end
    width = numel(sprintf('%d', max(channels)));
    fmt = sprintf('%%0%dd', width);
    labels = arrayfun(@(c) sprintf(fmt, c), channels, 'UniformOutput', false);
end
