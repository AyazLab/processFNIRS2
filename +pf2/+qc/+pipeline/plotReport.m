function fig = plotReport(qcReport, varargin)
% PLOTREPORT Visual QC dashboard showing all quality metrics
%
% Creates a 4-panel figure summarizing QC results across channels:
%   Top-left:     SCI bar chart with threshold line
%   Top-right:    Cardiac SNR bar chart with threshold line
%   Bottom-left:  CoV bar chart with threshold line
%   Bottom-right: Takizawa rule heatmap (4 rules x C channels)
%
% Uses the pf2_base.plot infrastructure (PlotStyle, createFigure,
% handleSave) for consistent styling.
%
% Syntax:
%   fig = pf2.qc.pipeline.plotReport(qcReport)
%   fig = pf2.qc.pipeline.plotReport(qcReport, 'Visible', 'off')
%   fig = pf2.qc.pipeline.plotReport(qcReport, 'SavePath', 'qc.png')
%
% Name-Value Parameters:
%   Visible  - 'on' (default) or 'off'
%   SavePath - File path for saving (default: '' = no save)
%   Title    - Figure super-title (default: 'QC Pipeline Report')
%
% Inputs:
%   qcReport - QC report struct from pf2.qc.pipeline.assess
%
% Outputs:
%   fig - Figure handle
%
% Example:
%   rpt = pf2.qc.pipeline.assess(data);
%   pf2.qc.pipeline.plotReport(rpt, 'SavePath', 'qc_dashboard.png');
%
% See also: pf2.qc.pipeline.assess, pf2.qc.pipeline.report

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
qcReport = pf2_base.args.check(qcReport, '', 'struct', {}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('plotReport', varargin, {}, {
    'Visible',     ('on'), '', '', {@mustBeText}
    'SavePath',    (''), '', '', {@mustBeText}
    'TightLayout', (false), '1,1', 'logical', {}
    'Title',       ('QC Pipeline Report'), '', '', {@mustBeText}
    });

%% Validate
assert(isfield(qcReport, 'pass'), 'pf2:qc:pipeline:badReport', ...
    'Input must be a QC report from pf2.qc.pipeline.assess.');

nChannels = numel(qcReport.channels);
chLabels = arrayfun(@num2str, 1:nChannels, 'UniformOutput', false);
sty = pf2_base.plot.PlotStyle.getDefault();

%% Create figure
fig = pf2_base.plot.createFigure('Visible', opts.Visible, ...
    'SavePath', opts.SavePath, 'Width', 1000, 'Height', 700);

passColor = [0.2, 0.7, 0.3];
failColor = [0.85, 0.2, 0.2];
barAlpha = 0.8;

%% Panel 1: SCI (top-left)
ax1 = subplot(2, 2, 1, 'Parent', fig);
if isfield(qcReport, 'sci') && ~(isfield(qcReport.sci, 'skipped') && qcReport.sci.skipped)
    vals = qcReport.sci.values;
    thresh = qcReport.sci.threshold;
    colors = repmat(passColor, nChannels, 1);
    colors(~qcReport.sci.pass, :) = repmat(failColor, sum(~qcReport.sci.pass), 1);

    b = bar(ax1, 1:nChannels, vals, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = colors;
    b.FaceAlpha = barAlpha;
    hold(ax1, 'on');
    plot(ax1, [0.5, nChannels+0.5], [thresh, thresh], 'r--', 'LineWidth', sty.LineWidth);
    hold(ax1, 'off');

    ylabel(ax1, 'SCI Score');
    title(ax1, sprintf('Scalp Coupling Index (threshold=%.2f)', thresh), ...
        'FontSize', sty.TitleFontSize);
    ylim(ax1, [0, 1]);
elseif isfield(qcReport, 'sci') && isfield(qcReport.sci, 'skipped') && qcReport.sci.skipped
    text(ax1, 0.5, 0.5, {'SCI skipped', '(fs too low)'}, ...
        'HorizontalAlignment', 'center', 'FontSize', sty.FontSize);
    title(ax1, 'Scalp Coupling Index', 'FontSize', sty.TitleFontSize);
else
    text(ax1, 0.5, 0.5, 'SCI not run', 'HorizontalAlignment', 'center', ...
        'FontSize', sty.FontSize);
    title(ax1, 'Scalp Coupling Index', 'FontSize', sty.TitleFontSize);
end
xlabel(ax1, 'Channel');
sty.applyToAxes(ax1);

%% Panel 2: Cardiac SNR (top-right)
ax2 = subplot(2, 2, 2, 'Parent', fig);
if isfield(qcReport, 'cardiac') && ~(isfield(qcReport.cardiac, 'skipped') && qcReport.cardiac.skipped)
    snrVals = qcReport.cardiac.snr;
    snrVals(isnan(snrVals)) = 0;
    thresh = qcReport.cardiac.threshold;
    colors = repmat(passColor, nChannels, 1);
    colors(~qcReport.cardiac.pass, :) = repmat(failColor, sum(~qcReport.cardiac.pass), 1);

    b = bar(ax2, 1:nChannels, snrVals, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = colors;
    b.FaceAlpha = barAlpha;
    hold(ax2, 'on');
    plot(ax2, [0.5, nChannels+0.5], [thresh, thresh], 'r--', 'LineWidth', sty.LineWidth);
    hold(ax2, 'off');

    ylabel(ax2, 'Cardiac SNR');
    title(ax2, sprintf('Cardiac Peak SNR (threshold=%.0f)', thresh), ...
        'FontSize', sty.TitleFontSize);
elseif isfield(qcReport, 'cardiac') && isfield(qcReport.cardiac, 'skipped') && qcReport.cardiac.skipped
    text(ax2, 0.5, 0.5, {'Cardiac skipped', '(fs too low)'}, ...
        'HorizontalAlignment', 'center', 'FontSize', sty.FontSize);
    title(ax2, 'Cardiac Peak SNR', 'FontSize', sty.TitleFontSize);
else
    text(ax2, 0.5, 0.5, 'Cardiac not run', 'HorizontalAlignment', 'center', ...
        'FontSize', sty.FontSize);
    title(ax2, 'Cardiac Peak SNR', 'FontSize', sty.TitleFontSize);
end
xlabel(ax2, 'Channel');
sty.applyToAxes(ax2);

%% Panel 3: CoV (bottom-left)
ax3 = subplot(2, 2, 3, 'Parent', fig);
if isfield(qcReport, 'cov')
    vals = qcReport.cov.values;
    thresh = qcReport.cov.threshold;
    colors = repmat(passColor, nChannels, 1);
    colors(~qcReport.cov.pass, :) = repmat(failColor, sum(~qcReport.cov.pass), 1);

    b = bar(ax3, 1:nChannels, vals, 'FaceColor', 'flat', 'EdgeColor', 'none');
    b.CData = colors;
    b.FaceAlpha = barAlpha;
    hold(ax3, 'on');
    plot(ax3, [0.5, nChannels+0.5], [thresh, thresh], 'r--', 'LineWidth', sty.LineWidth);
    hold(ax3, 'off');

    ylabel(ax3, 'CoV');
    title(ax3, sprintf('Coefficient of Variation (threshold=%.2f)', thresh), ...
        'FontSize', sty.TitleFontSize);
else
    text(ax3, 0.5, 0.5, 'CoV not run', 'HorizontalAlignment', 'center', ...
        'FontSize', sty.FontSize);
    title(ax3, 'Coefficient of Variation', 'FontSize', sty.TitleFontSize);
end
xlabel(ax3, 'Channel');
sty.applyToAxes(ax3);

%% Panel 4: Takizawa heatmap (bottom-right)
ax4 = subplot(2, 2, 4, 'Parent', fig);
if isfield(qcReport, 'takizawa')
    ruleData = double(qcReport.takizawa.rules);  % 4 x C, 1=pass 0=fail
    imagesc(ax4, ruleData);

    % Color: green=pass, red=fail
    colormap(ax4, [failColor; passColor]);
    caxis(ax4, [0, 1]);

    set(ax4, 'YTick', 1:4, 'YTickLabel', qcReport.takizawa.ruleNames);
    set(ax4, 'XTick', 1:nChannels, 'XTickLabel', chLabels);
    xlabel(ax4, 'Channel');
    title(ax4, 'Takizawa Rules (green=pass, red=fail)', ...
        'FontSize', sty.TitleFontSize);
else
    text(ax4, 0.5, 0.5, 'Takizawa not run', 'HorizontalAlignment', 'center', ...
        'FontSize', sty.FontSize);
    title(ax4, 'Takizawa Rules', 'FontSize', sty.TitleFontSize);
end
sty.applyToAxes(ax4);

%% Super-title
nPassed = sum(qcReport.pass);
pf2_base.external.suptitle(fig, sprintf('%s  —  %d/%d channels passed', ...
    opts.Title, nPassed, nChannels));

%% Save if requested
saveOpts.SavePath = opts.SavePath;
saveOpts.TightLayout = opts.TightLayout;
pf2_base.plot.handleSave(fig, saveOpts);

end
