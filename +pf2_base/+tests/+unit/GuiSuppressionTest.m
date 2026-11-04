classdef GuiSuppressionTest < matlab.unittest.TestCase
% GUISUPPRESSIONTEST Tests keep interactive windows from stalling a test run
%
% Checks that processFNIRS2 does not open its GUI by default inside the test
% framework, and that pf2_base.tests.CloseGUIsPlugin closes windows a test
% class leaves open while leaving windows that were open before the run.
%
% Usage:
%   results = runtests('pf2_base.tests.unit.GuiSuppressionTest');
%
% See also: pf2_base.underTestFramework, pf2_base.tests.CloseGUIsPlugin

    methods (Test, TestTags = {'GUI', 'Testing'})
        function testUnderTestFrameworkDetected(testCase)
            testCase.verifyTrue(pf2_base.underTestFramework());
        end

        function testProcessWithoutOutputOpensNoGUI(testCase)
            % processFNIRS2 called without an output would open its GUI;
            % inside the test framework it processes and returns instead
            data = pf2.import.sampleData.fNIR2000();
            before = findall(groot, 'Type', 'figure');
            processFNIRS2(data);
            after = findall(groot, 'Type', 'figure');
            testCase.verifyEqual(numel(after), numel(before), ...
                'No window should open inside the test framework');
        end

        function testPluginClosesLeftoverWindows(testCase)
            % A test class that leaves a figure open: the plugin deletes it
            % after the class, and a figure open before the run survives
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            fid = fopen(fullfile(folder, 'LeakyFigureTest.m'), 'w');
            fprintf(fid, ['classdef LeakyFigureTest < matlab.unittest.TestCase\n' ...
                '    methods (Test)\n' ...
                '        function leaves(~)\n' ...
                '            figure(''Visible'', ''off'', ''Tag'', ''pf2LeakyFigure'');\n' ...
                '        end\n' ...
                '    end\n' ...
                'end\n']);
            fclose(fid);
            keep = figure('Visible', 'off', 'Tag', 'pf2KeptFigure');
            testCase.addTeardown(@() delete(keep));
            oldPath = addpath(folder);
            testCase.addTeardown(@() path(oldPath));

            runner = matlab.unittest.TestRunner.withNoPlugins;
            runner.addPlugin(pf2_base.tests.CloseGUIsPlugin);
            result = runner.run(matlab.unittest.TestSuite.fromFile(fullfile(folder, 'LeakyFigureTest.m')));
            testCase.verifyTrue(result.Passed);
            testCase.verifyEmpty(findall(groot, 'Tag', 'pf2LeakyFigure'), ...
                'The figure left open by the test should be closed');
            testCase.verifyTrue(isvalid(keep), 'A figure open before the run should stay open');
        end
    end
end
