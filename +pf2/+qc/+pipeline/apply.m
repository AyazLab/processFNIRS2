function data = apply(data, report, varargin)
% APPLY Update fchMask based on a QC pipeline report
%
% ANDs the QC check results with the existing fchMask so that previously
% rejected channels are never promoted back to good. Stores the full
% report on the data struct for traceability.
%
% Syntax:
%   data = pf2.qc.pipeline.apply(data, report)
%   data = pf2.qc.pipeline.apply(data, report, 'Checks', {'sci', 'cardiac'})
%   data = pf2.qc.pipeline.apply(data, report, 'MarkNoisy', true)
%
% Name-Value Parameters:
%   Checks    - Which checks to use: 'all' (default) or cell array of
%               check names e.g. {'sci','takizawa'}
%   Mode      - 'and' (default): reject if ANY selected check fails
%   MarkNoisy - If true, set marginal channels to 0.5 instead of 0
%               (default: false)
%
% Inputs:
%   data   - fNIRS data struct with .fchMask
%   report - QC report from pf2.qc.pipeline.assess
%
% Outputs:
%   data - Modified data struct with updated .fchMask and .qcReport
%
% Example:
%   report = pf2.qc.pipeline.assess(data);
%   data = pf2.qc.pipeline.apply(data, report);
%   data = pf2.qc.pipeline.apply(data, report, 'Checks', {'sci', 'cardiac'});
%
% See also: pf2.qc.pipeline.assess, pf2.qc.pipeline.report

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
data = pf2_base.args.check(data, '', 'struct', {}, 'Invalid argument at position 1.');
report = pf2_base.args.check(report, '', 'struct', {}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('apply', varargin, {}, {
    'Checks',    ('all'), '', '', {}
    'Mode',      ('and'), '', '', {}
    'MarkNoisy', (false), '1,1', 'logical', {}
    });

%% Validate report
assert(isfield(report, 'pass'), 'pf2:qc:pipeline:badReport', ...
    'Report must contain a .pass field. Run pf2.qc.pipeline.assess first.');
assert(isfield(report, 'channels'), 'pf2:qc:pipeline:badReport', ...
    'Report must contain a .channels field.');
assert(isfield(data, 'fchMask'), 'pf2:qc:pipeline:noMask', ...
    'Data struct must contain a .fchMask field.');

nChannels = numel(data.fchMask);
nReportCh = numel(report.channels);
assert(nReportCh == nChannels, 'pf2:qc:pipeline:sizeMismatch', ...
    'Report has %d channels but data.fchMask has %d.', nReportCh, nChannels);

%% Resolve which checks to use
if ischar(opts.Checks) || isstring(opts.Checks)
    checksStr = char(opts.Checks);
    if strcmpi(checksStr, 'all')
        selectedChecks = report.checkNames;
    else
        selectedChecks = {checksStr};
    end
else
    selectedChecks = opts.Checks;
end

%% Compute combined pass mask from selected checks
combinedPass = true(1, nChannels);
for i = 1:numel(selectedChecks)
    checkName = lower(selectedChecks{i});
    assert(isfield(report, checkName), 'pf2:qc:pipeline:missingCheck', ...
        'Check ''%s'' not found in report. Available: %s', ...
        checkName, strjoin(report.checkNames, ', '));
    combinedPass = combinedPass & report.(checkName).pass;
end

%% Apply to fchMask (AND with existing — never promote)
existingMask = data.fchMask;

if opts.MarkNoisy
    % Channels that fail: set to 0.5 if currently good, leave 0 as 0
    newMask = existingMask;
    failedChannels = ~combinedPass;
    newMask(failedChannels & existingMask > 0) = 0.5;
else
    newMask = double(existingMask > 0) .* double(combinedPass);
end

data.fchMask = newMask;

%% Store report for traceability
data.qcReport = report;

end
