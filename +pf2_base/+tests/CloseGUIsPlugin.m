classdef CloseGUIsPlugin < matlab.unittest.plugins.TestRunnerPlugin
% CLOSEGUISPLUGIN Close windows that a test leaves open
%
% A test that opens the processFNIRS2 GUI, the channel-check GUI or another
% figure and does not close it can leave a window that stalls the rest of an
% interactive test run. This plugin closes, after each test class, every
% figure and app window that was not open when the run started (figures a
% class creates in its setup and shares across its tests stay open until
% the class finishes). Windows are deleted rather than closed, so a
% close-confirmation dialog cannot block. Windows that were open before the
% run are left alone.
%
% Syntax:
%   runner.addPlugin(pf2_base.tests.CloseGUIsPlugin);
%
% Example:
%   runner = matlab.unittest.TestRunner.withTextOutput;
%   runner.addPlugin(pf2_base.tests.CloseGUIsPlugin);
%   results = runner.run(pf2_base.tests.buildSuite('full'));
%
% See also: pf2_base.tests.runCI, pf2_base.tests.runAllTests,
%           pf2_base.underTestFramework

    properties (Access = private)
        Preexisting = gobjects(0)   % figures open when the run started
    end

    methods (Access = protected)
        function runSession(plugin, pluginData)
            plugin.Preexisting = findall(groot, 'Type', 'figure');
            runSession@matlab.unittest.plugins.TestRunnerPlugin(plugin, pluginData);
        end

        function teardownTestClass(plugin, pluginData)
            teardownTestClass@matlab.unittest.plugins.TestRunnerPlugin(plugin, pluginData);
            plugin.closeNewWindows();
        end
    end

    methods (Access = private)
        function closeNewWindows(plugin)
            figs = findall(groot, 'Type', 'figure');
            if isempty(figs)
                return;
            end
            stale = figs(~ismember(figs, plugin.Preexisting));
            for k = 1:numel(stale)
                try
                    delete(stale(k));
                catch
                end
            end
        end
    end
end
