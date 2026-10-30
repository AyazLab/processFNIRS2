classdef AllPlotsSmokeTest < matlab.unittest.TestCase
    % ALLPLOTSSMOKETEST Comprehensive smoke tests for all plot functions
    %
    % Verifies that every plot function in the toolbox can be called headless
    % without error and returns a valid figure handle.
    %
    %   results = runtests('pf2_base.tests.unit.AllPlotsSmokeTest');

    properties
        groups
        connResult
        fs
        T
        nChannels
    end

    methods (TestClassSetup)
        function setupData(testCase)
            testCase.fs = 10;
            testCase.T = 200;
            testCase.nChannels = 8;

            rng(42);
            T = testCase.T;
            nCh = testCase.nChannels;
            timeVec = linspace(0, T/testCase.fs, T)';

            % Build groups struct (mimics aggregate() output)
            for g = 1:2
                ga.time = timeVec;
                ga.units = 'uM';
                for bm = {'HbO','HbR','HbTotal','HbDiff','CBSI'}
                    b = bm{1};
                    ga.(b).Mean = randn(T, nCh) * 0.5;
                    ga.(b).SEM = abs(randn(T, nCh)) * 0.1;
                    ga.(b).SD = abs(randn(T, nCh)) * 0.2;
                    ga.(b).N = ones(T, nCh) * 5;
                    ga.(b).data = randn(T, nCh, 5) * 0.5;
                end
                testCase.groups(g).gbyGrand = ga;
                testCase.groups(g).gbyGrandBarFlat = ga;
                testCase.groups(g).gbyTables = table();
                testCase.groups(g).gbyFNIRS = {};
                testCase.groups(g).gbyFNIRS_pp = {};
                testCase.groups(g).label = sprintf('Group%d', g);
            end

            % Build connectivity result
            testCase.connResult.matrix = rand(nCh) * 0.8;
            testCase.connResult.matrix = ...
                (testCase.connResult.matrix + testCase.connResult.matrix') / 2;
            testCase.connResult.pmatrix = rand(nCh);
            testCase.connResult.channels = 1:nCh;
            testCase.connResult.method = 'pearson';
            testCase.connResult.biomarker = 'HbO';
            testCase.connResult.labels = arrayfun(@(c) sprintf('Ch%d', c), ...
                1:nCh, 'UniformOutput', false);
            testCase.connResult.useROI = false;
        end
    end


    %% Core Group Plots
    methods (Test)

        function testPlotTemporal(testCase)
            fig = exploreFNIRS.core.plotTemporal(testCase.groups, ...
                'Visible', 'off', 'Biomarkers', {'HbO'});
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotBar(testCase)
            fig = exploreFNIRS.core.plotBar(testCase.groups, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotTopo(testCase)
            fig = exploreFNIRS.core.plotTopo(testCase.groups, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotTopoPerGroup(testCase)
            fig = exploreFNIRS.core.plotTopo(testCase.groups, ...
                'Layout', 'pergroup', 'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotHeatmap(testCase)
            fig = exploreFNIRS.core.plotHeatmap(testCase.groups, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotComposite(testCase)
            panels = { ...
                struct('type', 'temporal', 'args', {{'Biomarkers', {'HbO'}}}), ...
                struct('type', 'bar', 'args', {{'Biomarker', 'HbO'}}) ...
            };
            fig = exploreFNIRS.core.plotComposite(testCase.groups, panels, ...
                'Layout', [1, 2], 'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

    end


    %% Connectivity Plots
    methods (Test)

        function testPlotMatrix(testCase)
            fig = exploreFNIRS.connectivity.plotMatrix(testCase.connResult, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotMatrixWithValues(testCase)
            fig = exploreFNIRS.connectivity.plotMatrix(testCase.connResult, ...
                'ShowValues', true, 'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotDirectedMatrix(testCase)
            result = testCase.connResult;
            result.matrix = rand(testCase.nChannels);  % asymmetric
            result.method = 'granger';

            fig = exploreFNIRS.connectivity.plotDirected(result, ...
                'Layout', 'matrix', 'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotDirectedCircular(testCase)
            result = testCase.connResult;
            result.matrix = rand(testCase.nChannels);
            result.method = 'granger';

            fig = exploreFNIRS.connectivity.plotDirected(result, ...
                'Layout', 'circular', 'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotChord(testCase)
            fig = exploreFNIRS.connectivity.plotChord(testCase.connResult, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotDynamicFC(testCase)
            nCh = 4;
            nWin = 10;
            dynResult.matrices = randn(nCh, nCh, nWin);
            dynResult.windowTimes = (1:nWin)' * 5;
            dynResult.method = 'pearson';
            dynResult.labels = arrayfun(@(c) sprintf('Ch%d', c), 1:nCh, ...
                'UniformOutput', false);

            fig = exploreFNIRS.connectivity.plotDynamicFC(dynResult, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

    end


    %% Coupling Plots
    methods (Test)

        function testPlotWindowed(testCase)
            rng(42);
            T = testCase.T;
            x = randn(T, 1);
            y = randn(T, 1);
            result = exploreFNIRS.coupling.pearson(x, y, testCase.fs, ...
                'WindowSize', 5);

            fig = exploreFNIRS.coupling.plotWindowed(result, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotWcoherence(testCase)
            rng(42);
            T = testCase.T;
            t = (0:T-1)' / testCase.fs;
            x = sin(2*pi*0.05*t) + randn(T, 1) * 0.3;
            y = sin(2*pi*0.05*t) + randn(T, 1) * 0.3;

            result = exploreFNIRS.coupling.wcoherence(x, y, testCase.fs);
            fig = exploreFNIRS.coupling.plotWcoherence(result, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

    end


    %% Hyperscanning Plots
    methods (Test)

        function testPlotGroupHyperscanning(testCase)
            nCh = testCase.nChannels;
            result.Mean = rand(nCh, 1) * 0.5;
            result.SEM = rand(nCh, 1) * 0.1;
            result.N = 5;
            result.method = 'pearson';
            result.biomarker = 'HbO';
            result.channels = 1:nCh;
            result.pvalue = rand(nCh, 1);
            result.tstat = randn(nCh, 1);
            result.dyads = {};

            fig = exploreFNIRS.hyperscanning.plotGroup(result, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotInterBrainTopo(testCase)
            nCh = testCase.nChannels;
            result.Mean = rand(nCh, 1) * 0.5;
            result.SEM = rand(nCh, 1) * 0.1;
            result.N = 5;
            result.method = 'pearson';
            result.biomarker = 'HbO';
            result.channels = 1:nCh;
            result.pvalue = rand(nCh, 1);
            result.tstat = randn(nCh, 1);
            result.dyads = {};

            fig = exploreFNIRS.hyperscanning.plotInterBrainTopo(result, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

        function testPlotDyadMatrix(testCase)
            nCh = 4;
            nDyads = 3;
            result.Mean = rand(nCh, 1) * 0.5;
            result.SEM = rand(nCh, 1) * 0.1;
            result.N = nDyads;
            result.method = 'pearson';
            result.biomarker = 'HbO';
            result.channels = 1:nCh;
            result.pvalue = rand(nCh, 1);
            result.tstat = randn(nCh, 1);
            result.dyads = cell(nDyads, 1);
            for d = 1:nDyads
                result.dyads{d}.values = rand(nCh, 1) * 0.6;
                result.dyads{d}.pvalues = rand(nCh, 1);
                result.dyads{d}.channelsA = 1:nCh;
                result.dyads{d}.channelsB = 1:nCh;
                result.dyads{d}.method = 'pearson';
                result.dyads{d}.pairing = 'same';
            end

            fig = exploreFNIRS.hyperscanning.plotDyadMatrix(result, ...
                'Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            close(fig);
        end

    end


    %% Style Infrastructure
    methods (Test)

        function testCreateFigure(testCase)
            % The white background is the light-theme result. Rendering
            % tests earlier in the suite (and exportgraphics) can leave
            % groot's defaultFigureColor dark, which PlotStyle reads as dark
            % mode, so pin light mode here as PlotStyleTest does.
            prevForceLight = pf2_base.plot.PlotStyle.getForceLightMode();
            pf2_base.plot.PlotStyle.setForceLightMode(true);
            restoreTheme = onCleanup(@() pf2_base.plot.PlotStyle.setForceLightMode(prevForceLight)); %#ok<NASGU>
            fig = pf2_base.plot.createFigure('Visible', 'off');
            testCase.verifyTrue(ishandle(fig));
            testCase.verifyEqual(get(fig, 'Color'), [1 1 1]);
            close(fig);
        end

        function testPlotStyleApply(testCase)
            fig = figure('Visible', 'off');
            cleanup = onCleanup(@() close(fig));
            ax = axes('Parent', fig);
            sty = pf2_base.plot.PlotStyle.getDefault();
            sty.applyToAxes(ax);
            testCase.verifyEqual(get(ax, 'FontSize'), 11);
        end

    end

    %% imageValues regression: probe geometry edge cases

    methods (Test)

        function testImageValuesNonContiguousChannels(testCase)
            % Merged probe has non-contiguous OptodeNum (5..42 over 34 rows).
            % Indexing the layout by OptodeNum value used to overflow.
            pf2.Device.clearCache();
            data.device = pf2.Device.load('fNIR_Hitachi_3x5_merged');
            data.info.probename = 'fNIR_Hitachi_3x5_merged';
            n = data.device.nChannels;
            fig = figure('Visible', 'off');
            cleanup = onCleanup(@() close(fig)); %#ok<NASGU>
            h = pf2.probe.plot.imageValues(1:n, data, [], [], 'merged', 'ch');
            testCase.verifyNotEmpty(h);
        end

        function testImageValuesLayoutOnlyDevice(testCase)
            % Layout-only (grid) device renders via the schematic grid.
            pf2.Device.clearCache();
            data.device = pf2.Device.load('NIRX_Sport_8x8_frontal');
            data.info.probename = 'NIRX_Sport_8x8_frontal';
            n = data.device.nChannels;
            fig = figure('Visible', 'off');
            cleanup = onCleanup(@() close(fig)); %#ok<NASGU>
            h = pf2.probe.plot.imageValues(1:n, data, [], [], 'nirx', 'ch', ...
                'Layout', 'schematic');
            testCase.verifyNotEmpty(h);
        end

    end

end
