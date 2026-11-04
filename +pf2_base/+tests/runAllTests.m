function results = runAllTests()
%RUNALLTESTS Run all processFNIRS2 unit and integration tests
%
%   results = pf2_base.tests.runAllTests() executes all unit tests and integration
%   tests in the processFNIRS2 test suite using the MATLAB Unit Testing
%   Framework (matlab.unittest).
%
%   Syntax:
%       results = pf2_base.tests.runAllTests()
%
%   Outputs:
%       results - matlab.unittest.TestResult array containing results for
%                 all executed tests. Each element contains:
%                   .Name    - Full test name (package.class/method)
%                   .Passed  - Logical, true if test passed
%                   .Failed  - Logical, true if test failed
%                   .Incomplete - Logical, true if test did not complete
%                   .Duration - Test execution time in seconds
%
%   Description:
%       This function runs the 'full' lane from pf2_base.tests.buildSuite: every
%       headless-safe TestCase under pf2_base.tests, including the root
%       testExperiment class, excluding only the UI lane. Tests execute with
%       verbose output (Verbosity level 3).
%
%       The function REPORTS results (total/passed/failed/incomplete, with the
%       names of any failed or incomplete tests) but does not itself signal
%       failure to the shell. To gate CI so the process exits non-zero on any
%       failure OR incomplete test, use pf2_base.tests.runCI instead.
%
%   Test Organization (see pf2_base.tests.buildSuite for the authoritative map):
%       pf2_base.tests.unit        - Unit tests for individual functions
%       pf2_base.tests.integration - Integration tests for multi-component workflows
%       pf2_base.tests.testExperiment - Experiment class tests (root of the package)
%
%   Example:
%       % Run all tests and examine results
%       results = pf2_base.tests.runAllTests();
%
%       % Check if all tests passed
%       if all([results.Passed])
%           disp('All tests passed!');
%       end
%
%       % Get failed test details
%       failedResults = results([results.Failed]);
%       for i = 1:numel(failedResults)
%           disp(failedResults(i).Details);
%       end
%
%   See also: pf2_base.tests.buildSuite, pf2_base.tests.runCI,
%             pf2_base.tests.runQuickTests, matlab.unittest.TestSuite

%   Author: processFNIRS2 Development Team
%   Version: 8.1
%   Last Updated: 2026-01-23

    import matlab.unittest.TestSuite;
    import matlab.unittest.TestRunner;
    import matlab.unittest.plugins.TestRunProgressPlugin;

    % Print header
    fprintf('=== processFNIRS2 Test Suite ===\n');
    fprintf('Running at: %s\n', datestr(now));
    fprintf('MATLAB Version: %s\n\n', version);

    % Build the authoritative headless suite (unit + integration + the root
    % testExperiment class, excluding the UI lane). Discovery lives in one
    % place, pf2_base.tests.buildSuite, so this runner cannot silently drift
    % out of sync with what the test tree actually contains.
    fprintf('Discovering tests (lane: full)...\n');
    suite = pf2_base.tests.buildSuite('full');

    if isempty(suite)
        fprintf('No tests discovered under pf2_base.tests.\n');
        fprintf('Ensure test classes inherit from matlab.unittest.TestCase.\n');
        results = matlab.unittest.TestResult.empty;
        return;
    end

    nClasses = numel(unique(regexprep(string({suite.Name}), '/.*$', '')));
    fprintf('Found %d tests across %d classes\n', numel(suite), nClasses);
    fprintf('\n');

    % Configure runner with verbose output
    runner = TestRunner.withTextOutput('Verbosity', 3);
    runner.addPlugin(pf2_base.tests.CloseGUIsPlugin);   % close windows tests leave open

    % Run all tests
    fprintf('--- Running Tests ---\n\n');
    results = runner.run(suite);

    % Print summary
    fprintf('\n');
    fprintf('=== TEST SUMMARY ===\n');
    fprintf('Total:      %d\n', numel(results));
    fprintf('Passed:     %d\n', sum([results.Passed]));
    fprintf('Failed:     %d\n', sum([results.Failed]));
    fprintf('Incomplete: %d\n', sum([results.Incomplete]));
    fprintf('Duration:   %.2f seconds\n', sum([results.Duration]));

    % List failed tests if any
    if any([results.Failed])
        fprintf('\nFailed tests:\n');
        failedTests = results([results.Failed]);
        for i = 1:numel(failedTests)
            fprintf('  - %s\n', failedTests(i).Name);
        end
        fprintf('\nRun individual failed tests for detailed diagnostics.\n');
    end

    % List incomplete tests if any
    if any([results.Incomplete])
        fprintf('\nIncomplete tests:\n');
        incompleteTests = results([results.Incomplete]);
        for i = 1:numel(incompleteTests)
            fprintf('  - %s\n', incompleteTests(i).Name);
        end
    end

    % Final status
    fprintf('\n');
    if all([results.Passed]) && ~any([results.Incomplete])
        fprintf('All tests PASSED.\n');
    else
        fprintf('Some tests FAILED or were INCOMPLETE.\n');
    end

    % Other lanes are run separately (they need a display or a fresh process):
    fprintf('\nOther lanes: pf2_base.tests.runCI(''ui''), runCI(''clean''), runCI(''quick'').\n');
    fprintf('To gate CI on the result (non-zero exit on any failure/incomplete):\n');
    fprintf('  matlab -batch "pf2_base.tests.runCI(''full'')"\n');
    fprintf('=== Test Run Complete ===\n');
end
