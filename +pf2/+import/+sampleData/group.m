function [ex, allData] = group(varargin)
% GROUP One-call synthetic multi-subject group ready for analysis
%
% Convenience on-ramp to Layer 2 (group analysis). Builds the synthetic
% 4-subject dataset from pf2.import.sampleData.experiment, then constructs,
% groups, and aggregates an exploreFNIRS.core.Experiment so you can call
% plotBar / plotLME / plotTopoLME immediately — no block-definition or
% extraction boilerplate required.
%
% This is the group-level counterpart to the single-subject helpers
% (pf2.import.sampleData.fNIR2000). Use it whenever you want a realistic
% group to try group statistics or visualizations against.
%
% Syntax:
%   ex = pf2.import.sampleData.group()
%   [ex, allData] = pf2.import.sampleData.group()
%   ex = pf2.import.sampleData.group('Conditions', {'Easy','Hard'})
%   ex = pf2.import.sampleData.group('GroupBy', {'Group','Condition'})
%
% Name-Value Parameters:
%   'Conditions' - Cell array of condition labels to keep (default: all,
%                  i.e. {'Easy','Hard','Rest'}). Passed to Experiment.select.
%   'GroupBy'    - Cell array of grouping variables (default: {'Condition'}).
%                  Common alternative: {'Group','Condition'} for age-group
%                  contrasts (the synthetic data has Young/Older subjects).
%
% Outputs:
%   ex      - A grouped, aggregated exploreFNIRS.core.Experiment (handle).
%             Ready for ex.plotBar(), ex.plotLME(), ex.plotTopoLME(), etc.
%   allData - The underlying {1 x 24} cell array of aligned block segments
%             (4 subjects x 6 blocks) used to build the Experiment, in case
%             you want to rebuild it with different grouping.
%
% Example:
%   % Group bar chart and LME significance map in four lines
%   ex = pf2.import.sampleData.group();
%   ex.plotBar('Biomarkers', {'HbO'});
%   [~, results] = ex.plotLME('Biomarkers', {'HbO'});
%   ex.plotTopoLME('Biomarkers', {'HbO'});
%
%   % Age-group contrast (Young vs Older)
%   ex = pf2.import.sampleData.group('GroupBy', {'Group','Condition'});
%
% See also: pf2.import.sampleData.experiment, pf2.import.sampleData.fNIR2000,
%           exploreFNIRS.core.Experiment

p = inputParser;
p.FunctionName = 'pf2.import.sampleData.group';
addParameter(p, 'Conditions', {}, @(x) iscell(x) || ischar(x) || isstring(x));
addParameter(p, 'GroupBy', {'Condition'}, @iscell);
parse(p, varargin{:});
opts = p.Results;

% Aligned block segments (4 subjects x 6 blocks), ready for Experiment
allData = pf2.import.sampleData('experiment', 'aligned');  % by-name form also works under Octave

% Build and prepare the Experiment
ex = exploreFNIRS.core.Experiment(allData);

if ~isempty(opts.Conditions)
    conds = opts.Conditions;
    if ~iscell(conds), conds = cellstr(conds); end
    ex.select('Condition', conds);
end

ex.groupby(opts.GroupBy);
ex.aggregate();

end
