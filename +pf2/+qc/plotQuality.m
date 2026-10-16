function fig = plotQuality(qcResult, varargin)
% PLOTQUALITY Visualize fNIRS signal quality metrics
%
% Dispatches based on the type of QC result passed in. Produces an SCI bar
% chart when the result has a .sci field, or a PSD line plot when the
% result has a .psd field.
%
% Syntax:
%   pf2.qc.plotQuality(sciResult)
%   pf2.qc.plotQuality(psdResult)
%   pf2.qc.plotQuality(psdResult, 'Layout', 'tiled')
%   fig = pf2.qc.plotQuality(qcResult, 'SavePath', 'quality.png')
%
% Name-Value Parameters:
%   'Channels' - [1 x C] subset of channels to plot (default: all)
%   'Layout'   - 'overlay' or 'tiled' for PSD plots (default: 'overlay')
%   'Visible'  - Figure visibility: 'on' or 'off' (default: 'on')
%   'SavePath' - File path to save figure. Empty = no save. (default: '')
%   'Title'    - Custom title string. Empty = auto title. (default: '')
%
% Inputs:
%   qcResult - Output struct from pf2.qc.sci or pf2.qc.powerSpectrum
%
% Outputs:
%   fig - (optional) Figure handle
%
% Modes:
%   A. SCI bar chart (when qcResult has .sci field):
%      - Bar chart of SCI per channel, colored green/red by threshold
%      - Horizontal dashed line at threshold
%
%   B. PSD plot (when qcResult has .psd field):
%      - Log-scale PSD line plot per channel
%      - Shaded bands for cardiac/respiratory/Mayer frequency ranges
%      - Diamond markers at detected peaks
%      - 'overlay' mode: all channels on one axes
%      - 'tiled' mode: subplot per channel
%
% Example:
%   sciResult = pf2.qc.sci(data);
%   pf2.qc.plotQuality(sciResult);
%
%   psdResult = pf2.qc.powerSpectrum(data, 'Signal', 'raw');
%   pf2.qc.plotQuality(psdResult, 'Layout', 'tiled', 'Visible', 'off');
%
% See also: pf2.qc.sci, pf2.qc.powerSpectrum

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
qcResult = pf2_base.args.check(qcResult, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('plotQuality', varargin, {}, {
    'Channels', ([]), '', '', {@mustBeNumeric}
    'Layout',   ('overlay'), '', '', {}
    'Visible',  ('on'), '', '', {}
    'SavePath', (''), '', '', {}
    'Title',    (''), '', '', {}
    });

%% Dispatch based on result type
if isfield(qcResult, 'sci')
    fig = plotSCI(qcResult, opts);
elseif isfield(qcResult, 'psd')
    fig = plotPSD(qcResult, opts);
else
    error('pf2:qc:plotQuality:unknownResult', ...
        'QC result must have .sci or .psd field.');
end

%% Save if requested
if ~isempty(char(opts.SavePath))
    saveas(fig, char(opts.SavePath));
end

if nargout == 0
    clear fig;
end

end


%% Local functions

function fig = plotSCI(result, opts)
% PLOTSCI Create SCI bar chart

channels = result.channels;
sciValues = result.sci;

% Subset channels if requested
if ~isempty(opts.Channels)
    [~, idx] = ismember(opts.Channels, channels);
    idx = idx(idx > 0);
    channels = channels(idx);
    sciValues = sciValues(idx);
end

nCh = numel(channels);
threshold = result.threshold;

% Create figure
fig = figure('Visible', opts.Visible);

% Color bars by threshold
colors = zeros(nCh, 3);
for i = 1:nCh
    if sciValues(i) >= threshold
        colors(i, :) = [0.2, 0.7, 0.3];  % Green
    else
        colors(i, :) = [0.8, 0.2, 0.2];  % Red
    end
end

% Draw bars
hold on;
for i = 1:nCh
    bar(i, sciValues(i), 'FaceColor', colors(i,:), 'EdgeColor', 'none');
end

% Threshold line
yline(threshold, '--k', sprintf('Threshold = %.2f', threshold), ...
    'LineWidth', 1.5, 'LabelHorizontalAlignment', 'left');

% Formatting
set(gca, 'XTick', 1:nCh, 'XTickLabel', arrayfun(@num2str, channels, 'UniformOutput', false));
xlabel('Channel');
ylabel('SCI');
ylim([0, 1]);

if isempty(char(opts.Title))
    title('Scalp Coupling Index');
else
    title(char(opts.Title));
end

hold off;

end


function fig = plotPSD(result, opts)
% PLOTPSD Create PSD line plot with physiological band overlays

freqs = result.freqs;
psdMatrix = result.psd;
channels = result.channels;

% Subset channels if requested
if ~isempty(opts.Channels)
    [~, idx] = ismember(opts.Channels, channels);
    idx = idx(idx > 0);
    channels = channels(idx);
    psdMatrix = psdMatrix(:, idx);
end

nCh = numel(channels);
layout = lower(char(opts.Layout));
if nCh == 0
    % No channels (e.g. all masked bad): tiled has no subplots to title,
    % so draw a single empty axes instead
    layout = 'overlay';
end

% Physiological bands for shading
bands = struct();
bands.mayer = [0.05, 0.15];
bands.respiratory = [0.1, 0.5];
bands.cardiac = [0.5, 2.5];

bandColors = struct();
bandColors.mayer = [0.6, 0.8, 1.0];       % Light blue
bandColors.respiratory = [0.6, 1.0, 0.6];  % Light green
bandColors.cardiac = [1.0, 0.8, 0.6];      % Light orange

bandLabels = struct();
bandLabels.mayer = 'Mayer';
bandLabels.respiratory = 'Respiratory';
bandLabels.cardiac = 'Cardiac';

fig = figure('Visible', opts.Visible);

if strcmp(layout, 'overlay')
    % All channels on one axes
    ax = axes(fig);
    hold(ax, 'on');

    % Draw band shading
    drawBandShading(ax, freqs, psdMatrix, bands, bandColors, bandLabels);

    % Plot each channel
    cmap = lines(nCh);
    legendEntries = cell(1, nCh);
    lineHandles = gobjects(1, nCh);

    for ch = 1:nCh
        lineHandles(ch) = semilogy(ax, freqs, psdMatrix(:, ch), ...
            'Color', cmap(ch, :), 'LineWidth', 1);
        legendEntries{ch} = sprintf('Ch %d', channels(ch));
    end

    % Mark detected peaks
    drawPeakMarkers(ax, result, channels, 1:nCh);

    legend(lineHandles, legendEntries, 'Location', 'northeast');
    xlabel(ax, 'Frequency (Hz)');
    ylabel(ax, 'PSD');
    set(ax, 'YScale', 'log');

    if isempty(char(opts.Title))
        title(ax, sprintf('Power Spectrum (%s)', result.signal));
    else
        title(ax, char(opts.Title));
    end

    hold(ax, 'off');

else
    % Tiled layout: subplot per channel
    nCols = ceil(sqrt(nCh));
    nRows = ceil(nCh / nCols);

    for ch = 1:nCh
        ax = subplot(nRows, nCols, ch);
        hold(ax, 'on');

        drawBandShading(ax, freqs, psdMatrix(:, ch), bands, bandColors, bandLabels);

        semilogy(ax, freqs, psdMatrix(:, ch), 'b', 'LineWidth', 1);

        % Mark detected peaks for this channel
        drawPeakMarkers(ax, result, channels, ch);

        title(ax, sprintf('Ch %d', channels(ch)));
        xlabel(ax, 'Freq (Hz)');
        ylabel(ax, 'PSD');
        set(ax, 'YScale', 'log');
        hold(ax, 'off');
    end

    if isempty(char(opts.Title))
        pf2_base.external.suptitle(sprintf('Power Spectrum (%s)', result.signal));
    else
        pf2_base.external.suptitle(char(opts.Title));
    end
end

end


function drawBandShading(ax, freqs, psdMatrix, bands, bandColors, bandLabels)
% DRAWBANDSHADING Add shaded frequency bands to axes

fMin = min(freqs);
fMax = max(freqs);
% An all-zero (or empty) spectrum, e.g. from a recording too short for a
% PSD, has no positive power to scale a log axis to
posPower = psdMatrix(psdMatrix > 0 & isfinite(psdMatrix));
if isempty(posPower)
    yLimits = [1e-10, 1];
else
    yLimits = [min(posPower) * 0.1, max(posPower) * 10];
end

bandNames = {'mayer', 'respiratory', 'cardiac'};
for i = 1:numel(bandNames)
    bName = bandNames{i};
    bLimits = bands.(bName);

    % Only draw if band overlaps with frequency range
    if bLimits(2) < fMin || bLimits(1) > fMax
        continue;
    end

    x1 = max(bLimits(1), fMin);
    x2 = min(bLimits(2), fMax);

    fill(ax, [x1, x2, x2, x1], ...
         [yLimits(1), yLimits(1), yLimits(2), yLimits(2)], ...
         bandColors.(bName), 'FaceAlpha', 0.2, 'EdgeColor', 'none', ...
         'HandleVisibility', 'off');
end

end


function drawPeakMarkers(ax, result, channels, chIndices)
% DRAWPEAKMARKERS Add diamond markers at detected peaks

peakFields = {'cardiac', 'respiratory', 'mayer'};
markerColors = {[0.8, 0.2, 0.0], [0.0, 0.6, 0.0], [0.0, 0.2, 0.8]};

for p = 1:numel(peakFields)
    fieldName = peakFields{p};
    if ~isfield(result, fieldName)
        continue;
    end

    peakData = result.(fieldName);
    for ch = chIndices
        % Find which index in peakData corresponds to this channel
        [~, peakIdx] = ismember(channels(ch), result.channels);
        if peakIdx == 0 || ~peakData.detected(peakIdx)
            continue;
        end

        semilogy(ax, peakData.freq(peakIdx), peakData.power(peakIdx), ...
            'd', 'MarkerSize', 8, 'MarkerFaceColor', markerColors{p}, ...
            'MarkerEdgeColor', 'k', 'HandleVisibility', 'off');
    end
end

end
