function results = runCI(lane)
%RUNCI Run a test lane as a gate: error on any failed OR incomplete test.
%
%   pf2_base.tests.runCI(lane) builds the requested lane with
%   pf2_base.tests.buildSuite, runs it, prints a one-line summary, and throws
%   if any test failed or was incomplete. It is the single command CI and
%   automation should use:
%
%       matlab -batch "pf2_base.tests.runCI('full')"
%
%   Under `matlab -batch`, an uncaught error makes the process exit non-zero,
%   so the gate actually fails the build. This replaces the fragile hand-written
%   `exit(any([results.Failed]))`, which ignored Incomplete tests (errored in
%   fixtures/setup) and let a broken suite report success.
%
%   Syntax:
%       results = pf2_base.tests.runCI()        % 'full' (default)
%       results = pf2_base.tests.runCI(lane)
%
%   Inputs:
%       lane - (char/string, optional) 'full' (default) | 'ui' | 'clean' |
%              'identity' | 'all' | 'quick'. All except 'quick' map to
%              pf2_base.tests.buildSuite lanes; 'quick' runs the lightweight
%              script validation lane (pf2_base.tests.runQuickTests).
%
%   Outputs:
%       results - matlab.unittest.TestResult array for the lane (empty for the
%                 'quick' lane, which is script-based). Only returned when
%                 requested; on failure the function errors regardless.
%
%   Example:
%       % Local pre-push gate over everything, including UI:
%       pf2_base.tests.runCI('all');
%
%   See also: pf2_base.tests.buildSuite, pf2_base.tests.runAllTests,
%             pf2_base.tests.runQuickTests

    import matlab.unittest.TestRunner;

    if nargin < 1 || isempty(lane)
        lane = 'full';
    end
    lane = lower(string(lane));

    % Quick lane is script-based; delegate and gate on its boolean status.
    if lane == "quick"
        ok = pf2_base.tests.runQuickTests();
        results = matlab.unittest.TestResult.empty;
        if ~ok
            error('pf2:tests:runCI:quickFailures', ...
                'Quick validation lane reported failures. See output above.');
        end
        return;
    end

    suite = pf2_base.tests.buildSuite(lane);
    if isempty(suite)
        error('pf2:tests:runCI:emptyLane', ...
            'Lane "%s" contains no tests. Nothing to gate on.', lane);
    end

    runner = TestRunner.withTextOutput('Verbosity', 2);
    runner.addPlugin(pf2_base.tests.CloseGUIsPlugin);   % close windows tests leave open
    results = runner.run(suite);

    nTotal      = numel(results);
    nPassed     = sum([results.Passed]);
    nFailed     = sum([results.Failed]);
    nIncomplete = sum([results.Incomplete]);

    fprintf('\n[runCI:%s] total=%d passed=%d failed=%d incomplete=%d duration=%.1fs\n', ...
        lane, nTotal, nPassed, nFailed, nIncomplete, sum([results.Duration]));

    if nFailed > 0 || nIncomplete > 0
        error('pf2:tests:runCI:failures', ...
            'Lane "%s" is not green: %d failed, %d incomplete (of %d). See output above.', ...
            lane, nFailed, nIncomplete, nTotal);
    end
end
