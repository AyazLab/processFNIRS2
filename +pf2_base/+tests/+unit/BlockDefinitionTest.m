classdef BlockDefinitionTest < matlab.unittest.TestCase
    % BLOCKDEFINITIONTEST Unit tests for pf2.data.defineBlocks and pf2.data.extractBlocks
    %
    % Tests block definition from markers (three modes) and block extraction
    % to cell arrays. Covers ConditionMap, InfoTable, InfoFields, duration
    % filtering, baseline subtraction, time shifting, and info merging.
    %
    % Run all tests:
    %   results = runtests('pf2_base.tests.unit.BlockDefinitionTest');
    %
    % See also: pf2.data.defineBlocks, pf2.data.extractBlocks

    properties
        processedData   % Processed fNIRS sample data
    end

    methods (TestClassSetup)
        function loadSampleData(testCase)
            raw = pf2.import.sampleData.fNIR2000();
            testCase.processedData = processFNIRS2(raw);
        end
    end

    methods (Static)
        function data = makeSyntheticData()
            % Create minimal fNIRS struct with synthetic markers for testing
            fs = 10;
            T = 300; % 300 seconds
            nSamples = T * fs;
            nCh = 4;
            t = (0:nSamples-1)' / fs;

            data.time = t;
            data.fs = fs;
            data.HbO = randn(nSamples, nCh) * 0.01;
            data.HbR = randn(nSamples, nCh) * 0.005;
            data.HbDiff = data.HbO - data.HbR;
            data.HbTotal = data.HbO + data.HbR;
            data.CBSI = randn(nSamples, nCh) * 0.008;
            data.fchMask = ones(1, nCh);
            data.info = struct('SubjectID', 'S01', 'Task', 'Test');

            % Markers: [time, code, duration, amplitude]
            % 3 blocks of marker 49 at t=30, 90, 180 with durations 20, 25, 30
            data.markers = pf2_base.normalizeMarkers([
                30,  49, 20, 1;
                90,  49, 25, 1;
                180, 49, 30, 1;
            ]);
        end

        function data = makePairedMarkerData()
            % Create data with start/end marker pairs
            fs = 10;
            T = 300;
            nSamples = T * fs;
            nCh = 4;
            t = (0:nSamples-1)' / fs;

            data.time = t;
            data.fs = fs;
            data.HbO = randn(nSamples, nCh) * 0.01;
            data.HbR = randn(nSamples, nCh) * 0.005;
            data.HbDiff = data.HbO - data.HbR;
            data.HbTotal = data.HbO + data.HbR;
            data.CBSI = randn(nSamples, nCh) * 0.008;
            data.fchMask = ones(1, nCh);
            data.info = struct('SubjectID', 'S01');

            % Start/end pairs: condition A (50->52), condition B (51->53)
            data.markers = pf2_base.normalizeMarkers([
                20,  50, 0, 1;   % Start A block 1
                45,  52, 0, 1;   % End A block 1
                60,  51, 0, 1;   % Start B block 1
                90,  53, 0, 1;   % End B block 1
                120, 50, 0, 1;   % Start A block 2
                155, 52, 0, 1;   % End A block 2
                200, 51, 0, 1;   % Start B block 2
                240, 53, 0, 1;   % End B block 2
            ]);
        end

        function out = suppressWarn(fcn)
            % Run fcn with the default-buffer warning suppressed and restored
            ws = warning('off', 'pf2:extractBlocks:defaultBuffer');
            cleanup = onCleanup(@() warning(ws)); %#ok<NASGU>
            out = fcn();
        end
    end

    %% defineBlocks - Marker + Fixed Duration
    methods (Test)
        function testMarkerFixedDuration(testCase)
            % Marker code + fixed duration creates correct blocks
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 15, 'Embed', false);

            testCase.verifyLength(blocks, 3, 'Should find 3 blocks');
            testCase.verifyEqual(blocks(1).startTime, 30, 'First block starts at marker time');
            testCase.verifyEqual(blocks(1).endTime, 45, 'First block ends at start + duration');
            testCase.verifyEqual(blocks(1).duration, 15, 'Duration should be 15s');
            testCase.verifyEqual(blocks(1).markerCode, 49, 'Marker code preserved');
        end

        function testMarkerFixedDurationBlockNumbers(testCase)
            % BlockNumber auto-assigned sequentially
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 15, 'Embed', false);

            for k = 1:length(blocks)
                testCase.verifyEqual(blocks(k).info.BlockNumber, k, ...
                    sprintf('Block %d should have BlockNumber = %d', k, k));
            end
        end
    end

    %% defineBlocks - Marker Duration from Column 3
    methods (Test)
        function testMarkerUseDuration(testCase)
            % UseDuration flag reads duration from markers column 3
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'UseDuration', true, 'Embed', false);

            testCase.verifyLength(blocks, 3);
            testCase.verifyEqual(blocks(1).duration, 20, 'Block 1 duration from col 3');
            testCase.verifyEqual(blocks(2).duration, 25, 'Block 2 duration from col 3');
            testCase.verifyEqual(blocks(3).duration, 30, 'Block 3 duration from col 3');
            testCase.verifyEqual(blocks(1).endTime, 50, 'endTime = startTime + duration');
        end
    end

    %% defineBlocks - Start/End Pairs
    methods (Test)
        function testStartEndPairs(testCase)
            % Paired start/end markers produce correct windows
            data = pf2_base.tests.unit.BlockDefinitionTest.makePairedMarkerData();
            blocks = pf2.data.defineBlocks(data, ...
                'StartMarker', [50; 51], 'EndMarker', [52; 53], 'Embed', false);

            testCase.verifyLength(blocks, 4, 'Should find 4 blocks (2 per condition)');

            % Sorted by time: A1(20-45), B1(60-90), A2(120-155), B2(200-240)
            testCase.verifyEqual(blocks(1).startTime, 20);
            testCase.verifyEqual(blocks(1).endTime, 45);
            testCase.verifyEqual(blocks(1).duration, 25);
            testCase.verifyEqual(blocks(2).startTime, 60);
            testCase.verifyEqual(blocks(2).endTime, 90);
        end
    end

    %% defineBlocks - ConditionMap
    methods (Test)
        function testConditionMap(testCase)
            % ConditionMap assigns condition labels per marker code
            data = pf2_base.tests.unit.BlockDefinitionTest.makePairedMarkerData();
            blocks = pf2.data.defineBlocks(data, ...
                'StartMarker', [50; 51], 'EndMarker', [52; 53], ...
                'ConditionMap', {50, 'Natural'; 51, 'Synthetic'}, 'Embed', false);

            % Sorted by time: A1(50), B1(51), A2(50), B2(51)
            testCase.verifyEqual(blocks(1).info.Condition, 'Natural');
            testCase.verifyEqual(blocks(2).info.Condition, 'Synthetic');
            testCase.verifyEqual(blocks(3).info.Condition, 'Natural');
            testCase.verifyEqual(blocks(4).info.Condition, 'Synthetic');
        end

        function testConditionMapWithMarkerCode(testCase)
            % ConditionMap works with MarkerCode mode using OR logic
            data = pf2_base.tests.unit.BlockDefinitionTest.makePairedMarkerData();

            % Use column vector for OR: find markers 50 or 51
            blocks = pf2.data.defineBlocks(data, ...
                'MarkerCode', [50; 51], 'Duration', 10, ...
                'ConditionMap', {50, 'CondA'; 51, 'CondB'}, 'Embed', false);

            testCase.verifyLength(blocks, 4, 'Should find 4 markers (2x50 + 2x51)');
            testCase.verifyEqual(blocks(1).info.Condition, 'CondA');
            testCase.verifyEqual(blocks(2).info.Condition, 'CondB');
        end
    end

    %% defineBlocks - InfoTable
    methods (Test)
        function testInfoTable(testCase)
            % Per-block table columns become .info fields
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            scores = table([85; 92; 78], {'Easy';'Hard';'Easy'}, ...
                'VariableNames', {'Score','Difficulty'});

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 15, 'InfoTable', scores, 'Embed', false);

            testCase.verifyEqual(blocks(1).info.Score, 85);
            testCase.verifyEqual(blocks(2).info.Difficulty, 'Hard');
            testCase.verifyEqual(blocks(3).info.Score, 78);
        end
    end

    %% defineBlocks - InfoFields
    methods (Test)
        function testInfoFields(testCase)
            % Constant InfoFields applied to all blocks
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 15, 'InfoFields', struct('Task', 'Stroop', 'Group', 'Control'), 'Embed', false);

            for k = 1:length(blocks)
                testCase.verifyEqual(blocks(k).info.Task, 'Stroop');
                testCase.verifyEqual(blocks(k).info.Group, 'Control');
            end
        end
    end

    %% defineBlocks - MinDuration Filter
    methods (Test)
        function testMinDurationFilter(testCase)
            % Blocks shorter than MinDuration are rejected
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            % Durations are 20, 25, 30 from column 3
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'UseDuration', true, 'MinDuration', 22, 'Embed', false);

            testCase.verifyLength(blocks, 2, ...
                'Should reject block with duration=20 (< MinDuration=22)');
            testCase.verifyEqual(blocks(1).duration, 25);
            testCase.verifyEqual(blocks(2).duration, 30);
            % BlockNumbers should be renumbered after filtering
            testCase.verifyEqual(blocks(1).info.BlockNumber, 1);
            testCase.verifyEqual(blocks(2).info.BlockNumber, 2);
        end

        function testMaxDurationFilter(testCase)
            % Blocks longer than MaxDuration are rejected
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'UseDuration', true, 'MaxDuration', 27, 'Embed', false);

            testCase.verifyLength(blocks, 2, ...
                'Should reject block with duration=30 (> MaxDuration=27)');
        end
    end

    %% defineBlocks - Empty Markers
    methods (Test)
        function testEmptyMarkers(testCase)
            % No matching markers returns empty struct array
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = testCase.verifyWarning(@() pf2.data.defineBlocks(data, ...
                'MarkerCode', 999, 'Duration', 10, 'Embed', false), ...
                'pf2:defineBlocks:codesNotFound');

            testCase.verifyEmpty(blocks, 'Should return empty for no matching markers');
            testCase.verifyTrue(isstruct(blocks), 'Empty result should still be struct');
        end

        function testEmptyMarkerArray(testCase)
            % Data with empty markers returns empty
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([]);
            blocks = testCase.verifyWarning(@() pf2.data.defineBlocks(data, ...
                'MarkerCode', 49, 'Duration', 10, 'Embed', false), ...
                'pf2:defineBlocks:noMarkers');

            testCase.verifyEmpty(blocks);
        end

        function testCodesNotFoundNamesPresentCodes(testCase)
            % The warning lists the codes that are present and the recording
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            lastwarn('', '');
            w = warning('off', 'pf2:defineBlocks:codesNotFound');
            restore = onCleanup(@() warning(w));
            pf2.data.defineBlocks(data, 'MarkerCode', [7 8], 'Duration', 10, 'Embed', false);
            [msg, wid] = lastwarn();
            testCase.verifyEqual(wid, 'pf2:defineBlocks:codesNotFound');
            testCase.verifySubstring(msg, '7, 8');
            testCase.verifySubstring(msg, 'Codes present: 49');
            testCase.verifySubstring(msg, 'for S01');
        end

        function testMalformedMarkerColumnsHint(testCase)
            % Marker columns given as [code, time] put times in the Code
            % column; the warning points at the column order.
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([49 30.5; 49 90.25; 49 180.75]);
            lastwarn('', '');
            w = warning('off', 'pf2:defineBlocks:codesNotFound');
            restore = onCleanup(@() warning(w));
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 10, 'Embed', false);
            [msg, wid] = lastwarn();
            testCase.verifyEmpty(blocks);
            testCase.verifyEqual(wid, 'pf2:defineBlocks:codesNotFound');
            testCase.verifySubstring(msg, 'out of order');
        end

        function testNoPairedBlocksWarning(testCase)
            % Start codes present but no end code after them
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            % End code 2 occurs only before every start code 1.
            data.markers = pf2_base.normalizeMarkers([5 2; 10 1; 30 1]);
            blocks = testCase.verifyWarning(@() pf2.data.defineBlocks(data, ...
                'StartMarker', 1, 'EndMarker', 2, 'Embed', false), ...
                'pf2:defineBlocks:noPairedBlocks');
            testCase.verifyEmpty(blocks);
        end

        function testAllBlocksFilteredWarning(testCase)
            % Every block shorter than MinDuration
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = testCase.verifyWarning(@() pf2.data.defineBlocks(data, ...
                'MarkerCode', 49, 'MinDuration', 100, 'Embed', false), ...
                'pf2:defineBlocks:allBlocksFiltered');
            testCase.verifyEmpty(blocks);
        end

        function testMatchingCodesDoNotWarn(testCase)
            % A normal call raises none of the zero-block warnings
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            lastwarn('', '');
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', [49 7], 'Duration', 10, 'Embed', false);
            [~, wid] = lastwarn();
            testCase.verifyNumElements(blocks, 3);
            testCase.verifyFalse(startsWith(wid, 'pf2:defineBlocks:'), ...
                sprintf('Unexpected warning %s', wid));
        end
    end

    %% extractBlocks - Basic Extraction
    methods (Test)
        function testBasicExtraction(testCase)
            % Extract blocks produces correct number of segments
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);
            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 0, 'PostTime', 0, 'SetT0', false);

            testCase.verifyLength(segments, 3, 'Should extract 3 segments');

            % Each segment should have time within block bounds
            for k = 1:length(segments)
                seg = segments{k};
                testCase.verifyTrue(isfield(seg, 'HbO'), 'Segment should have HbO');
                testCase.verifyTrue(isfield(seg, 'time'), 'Segment should have time');
                testCase.verifyGreaterThanOrEqual(min(seg.time), blocks(k).startTime - 0.5, ...
                    'Segment time should start near block start');
                testCase.verifyLessThanOrEqual(max(seg.time), blocks(k).endTime + 0.5, ...
                    'Segment time should end near block end');
            end
        end
    end

    %% extractBlocks - PreTime/PostTime
    methods (Test)
        function testPreTimePostTime(testCase)
            % PreTime and PostTime extend extraction window
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            % Extract with 5s pre and 3s post, no T0 shift for easier verification
            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 5, 'PostTime', 3, 'SetT0', false);

            seg = segments{1};
            expectedStart = blocks(1).startTime - 5;
            expectedEnd = blocks(1).endTime + 3;

            testCase.verifyLessThanOrEqual(min(seg.time), expectedStart + 0.2, ...
                'Segment should start at block start - PreTime');
            testCase.verifyGreaterThanOrEqual(max(seg.time), expectedEnd - 0.2, ...
                'Segment should end at block end + PostTime');
        end
    end

    %% extractBlocks - BaselineWindow
    methods (Test)
        function testBaselineWindow(testCase)
            % BaselineWindow applies baseline subtraction
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            % Add a known offset to HbO so baseline subtraction is visible
            data.HbO = data.HbO + 5;

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            % Extract without baseline
            segsNoBL = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 0, 'PostTime', 0, 'SetT0', false);

            % Extract with baseline: [-5, 0] relative to block start
            % Need PreTime >= 5 to include baseline period in extraction
            segsBL = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 5, 'BaselineWindow', [-5, 0], 'SetT0', false);

            % Baseline-corrected data should have lower mean than uncorrected
            meanNoBL = mean(segsNoBL{1}.HbO(:));
            meanBL = mean(segsBL{1}.HbO(:));
            testCase.verifyLessThan(abs(meanBL), abs(meanNoBL), ...
                'Baseline correction should reduce mean offset');
        end
    end

    %% extractBlocks - SetT0
    methods (Test)
        function testSetT0(testCase)
            % SetT0 shifts time so block start = 0
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 0, 'PostTime', 0, 'SetT0', true);

            for k = 1:length(segments)
                seg = segments{k};
                testCase.verifyEqual(min(seg.time), 0, 'AbsTol', 0.2, ...
                    'Time should start near 0 after SetT0');
            end
        end

        function testSetT0WithPreTime(testCase)
            % With PreTime, time starts at negative value
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 5, 'SetT0', true);

            seg = segments{1};
            testCase.verifyLessThan(min(seg.time), 0, ...
                'With PreTime, time should start before 0');
            testCase.verifyEqual(min(seg.time), -5, 'AbsTol', 0.2, ...
                'Time should start near -PreTime');
        end
    end

    %% extractBlocks - Info Merging
    methods (Test)
        function testInfoMerging(testCase)
            % Parent data.info merged with block.info
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 20, 'ConditionMap', {49, 'StroopTask'}, 'Embed', false);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks));

            seg = segments{1};
            % Parent info fields preserved
            testCase.verifyEqual(seg.info.SubjectID, 'S01', ...
                'Parent SubjectID should be copied');
            testCase.verifyEqual(seg.info.Task, 'Test', ...
                'Parent Task field should be preserved');
            % Block info fields overlaid
            testCase.verifyTrue(isfield(seg.info, 'BlockNumber'), ...
                'BlockNumber should be present');
            testCase.verifyEqual(seg.info.Condition, 'StroopTask', ...
                'Condition from ConditionMap should be present');
        end

        function testOverwriteInfoFalse(testCase)
            % OverwriteInfo=false prevents block.info from overwriting parent fields
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.info.Condition = 'ParentCondition';  % set on parent
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, ...
                'ConditionMap', {49, 'BlockCondition'}, 'Embed', false);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks, 'OverwriteInfo', false));

            seg = segments{1};
            testCase.verifyEqual(seg.info.Condition, 'ParentCondition', ...
                'Parent Condition should be preserved when OverwriteInfo=false');
            testCase.verifyEqual(seg.info.SubjectID, 'S01', ...
                'Parent info always copied');
            testCase.verifyTrue(isfield(seg.info, 'BlockNumber'), ...
                'Block-only fields should still be added');
        end

        function testOverwriteInfoTrue(testCase)
            % OverwriteInfo=true (default) lets block.info overwrite parent fields
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.info.Condition = 'ParentCondition';
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, ...
                'ConditionMap', {49, 'BlockCondition'}, 'Embed', false);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks));

            seg = segments{1};
            testCase.verifyEqual(seg.info.Condition, 'BlockCondition', ...
                'Block Condition should overwrite parent when OverwriteInfo=true');
        end
    end

    %% extractBlocks - SkipInvalid
    methods (Test)
        function testSkipInvalid(testCase)
            % Blocks outside data range are skipped
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();

            % Create blocks manually, one out of range
            blocks(1).startTime = 30;
            blocks(1).endTime = 50;
            blocks(1).duration = 20;
            blocks(1).markerCode = 49;
            blocks(1).markerIndex = 1;
            blocks(1).info = struct('BlockNumber', 1);

            blocks(2).startTime = 500;  % Beyond data range (300s)
            blocks(2).endTime = 520;
            blocks(2).duration = 20;
            blocks(2).markerCode = 49;
            blocks(2).markerIndex = 2;
            blocks(2).info = struct('BlockNumber', 2);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks, 'SkipInvalid', true));

            testCase.verifyLength(segments, 1, ...
                'Out-of-range block should be skipped');
        end
    end

    %% Integration: defineBlocks -> extractBlocks -> Experiment
    methods (Test)
        function testEndToEndPipeline(testCase)
            % Full pipeline: define blocks, extract, verify cell array structure
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'UseDuration', true, ...
                'ConditionMap', {49, 'StroopTask'}, ...
                'InfoFields', struct('Group', 'Control'), 'Embed', false);

            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 5, 'PostTime', 2, 'SetT0', true);

            testCase.verifyLength(segments, 3, 'Should have 3 segments');

            % Verify each segment is a valid fNIRS struct
            for k = 1:length(segments)
                seg = segments{k};
                testCase.verifyTrue(isfield(seg, 'HbO'), 'Must have HbO');
                testCase.verifyTrue(isfield(seg, 'time'), 'Must have time');
                testCase.verifyTrue(isfield(seg, 'info'), 'Must have info');
                testCase.verifyEqual(seg.info.Condition, 'StroopTask');
                testCase.verifyEqual(seg.info.Group, 'Control');
                testCase.verifyEqual(seg.info.SubjectID, 'S01');
                testCase.verifyEqual(seg.info.BlockNumber, k);

                % Time should start near -5 (PreTime) after SetT0
                testCase.verifyEqual(min(seg.time), -5, 'AbsTol', 0.2);
            end
        end

        function testWithRealSampleData(testCase)
            % Verify with real processed sample data
            data = testCase.processedData;

            % Add synthetic markers to real data
            timeVec = data.time;
            minT = min(timeVec);
            data.markers = pf2_base.normalizeMarkers([
                minT + 30, 10, 20, 1;
                minT + 80, 10, 20, 1;
            ]);

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 10, 'Duration', 20, 'Embed', false);
            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks, 'SetT0', true));

            testCase.verifyLength(segments, 2);
            testCase.verifyTrue(isfield(segments{1}, 'HbO'));
            testCase.verifyEqual(size(segments{1}.HbO, 2), size(data.HbO, 2), ...
                'Channel count should be preserved');
        end
    end

    %% defineBlocks - Positional API
    methods (Test)
        function testPositionalCodesAndDuration(testCase)
            % Simple positional syntax: defineBlocks(data, codes, duration)
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, [49], 15, 'Embed', false);

            testCase.verifyLength(blocks, 3, 'Should find 3 blocks');
            testCase.verifyEqual(blocks(1).duration, 15);
            testCase.verifyEqual(blocks(1).startTime, 30);
        end

        function testPositionalMultipleCodes(testCase)
            % Multiple codes as row vector: defineBlocks(data, [49, 50], 30)
            data = pf2_base.tests.unit.BlockDefinitionTest.makePairedMarkerData();
            blocks = pf2.data.defineBlocks(data, [50, 51], 10, 'Embed', false);

            testCase.verifyLength(blocks, 4, 'Should find 4 blocks (2x50 + 2x51)');
        end

        function testPositionalAutoDuration(testCase)
            % No duration given: auto-detect from marker column 3
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 49, 'Embed', false);

            testCase.verifyLength(blocks, 3);
            testCase.verifyEqual(blocks(1).duration, 20, ...
                'Should auto-use duration from marker column 3');
            testCase.verifyEqual(blocks(2).duration, 25);
            testCase.verifyEqual(blocks(3).duration, 30);
        end

        function testPositionalWithNameValue(testCase)
            % Positional codes + name-value params mixed
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 49, 15, ...
                'ConditionMap', {49, 'Stroop'}, 'Embed', false);

            testCase.verifyLength(blocks, 3);
            testCase.verifyEqual(blocks(1).info.Condition, 'Stroop');
            testCase.verifyEqual(blocks(1).duration, 15);
        end
    end

    %% defineBlocks - PrePad/PostPad
    methods (Test)
        function testPrePadPostPad(testCase)
            % PrePad and PostPad extend block boundaries
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 49, 20, ...
                'PrePad', 5, 'PostPad', 3, 'Embed', false);

            testCase.verifyEqual(blocks(1).startTime, 25, ...
                'startTime should be 30 - 5 PrePad = 25');
            testCase.verifyEqual(blocks(1).endTime, 53, ...
                'endTime should be 50 + 3 PostPad = 53');
            testCase.verifyEqual(blocks(1).duration, 28, ...
                'duration = 20 + 5 + 3 = 28');
        end
    end

    %% defineBlocks - MarkerCode + EndMarker
    methods (Test)
        function testMarkerCodeWithEndMarker(testCase)
            % Single start code + single end code via MarkerCode + EndMarker
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 25 51 0 1; 40 49 0 1; 55 51 0 1]);

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'EndMarker', 51, 'Embed', false);

            testCase.verifyLength(blocks, 2, 'Should find 2 blocks');
            testCase.verifyEqual(blocks(1).startTime, 10);
            testCase.verifyEqual(blocks(1).endTime, 25);
            testCase.verifyEqual(blocks(1).duration, 15);
            testCase.verifyEqual(blocks(2).startTime, 40);
            testCase.verifyEqual(blocks(2).endTime, 55);
            testCase.verifyEqual(blocks(2).duration, 15);
        end

        function testMarkerCodeWithEndMarkerPairs(testCase)
            % Per-code end markers: 49->59, 48->58
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 20 59 0 1; 30 48 0 1; 45 58 0 1]);

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', [49 48], ...
                'EndMarker', [59 58], 'Embed', false);

            testCase.verifyLength(blocks, 2, 'Should find 2 blocks');
            % Sorted by time
            testCase.verifyEqual(blocks(1).startTime, 10);
            testCase.verifyEqual(blocks(1).endTime, 20);
            testCase.verifyEqual(blocks(1).markerCode, 49);
            testCase.verifyEqual(blocks(2).startTime, 30);
            testCase.verifyEqual(blocks(2).endTime, 45);
            testCase.verifyEqual(blocks(2).markerCode, 48);
        end

        function testPositionalCodesWithEndMarker(testCase)
            % Positional API: defineBlocks(data, 49, 'EndMarker', 51)
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 30 51 0 1]);

            blocks = pf2.data.defineBlocks(data, 49, 'EndMarker', 51, 'Embed', false);

            testCase.verifyLength(blocks, 1);
            testCase.verifyEqual(blocks(1).startTime, 10);
            testCase.verifyEqual(blocks(1).endTime, 30);
            testCase.verifyEqual(blocks(1).duration, 20);
        end

        function testMarkerCodeEndMarkerSharedEnd(testCase)
            % Multiple start codes with one shared EndMarker (scalar broadcast)
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 25 51 0 1; 40 50 0 1; 55 51 0 1]);

            blocks = pf2.data.defineBlocks(data, [49 50], 'EndMarker', 51, 'Embed', false);

            testCase.verifyLength(blocks, 2, 'Should find 2 blocks');
            testCase.verifyEqual(blocks(1).startTime, 10);
            testCase.verifyEqual(blocks(1).endTime, 25);
            testCase.verifyEqual(blocks(1).markerCode, 49);
            testCase.verifyEqual(blocks(2).startTime, 40);
            testCase.verifyEqual(blocks(2).endTime, 55);
            testCase.verifyEqual(blocks(2).markerCode, 50);
        end

        function testMarkerCodeEndMarkerWithConditionMap(testCase)
            % ConditionMap works in MarkerCode+EndMarker mode
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 25 51 0 1; 40 50 0 1; 55 51 0 1]);

            blocks = pf2.data.defineBlocks(data, [49 50], 'EndMarker', 51, ...
                'ConditionMap', {49, 'CondA'; 50, 'CondB'}, 'Embed', false);

            testCase.verifyLength(blocks, 2);
            testCase.verifyEqual(blocks(1).info.Condition, 'CondA');
            testCase.verifyEqual(blocks(2).info.Condition, 'CondB');
        end

        function testMarkerCodeEndMarkerMissingEnd(testCase)
            % Start marker with no subsequent end marker is skipped
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            % Second start (40) has no end marker after it
            data.markers = pf2_base.normalizeMarkers([10 49 0 1; 25 51 0 1; 40 49 0 1]);

            blocks = pf2.data.defineBlocks(data, 49, 'EndMarker', 51, 'Embed', false);

            testCase.verifyLength(blocks, 1, ...
                'Second start with no end should be skipped');
            testCase.verifyEqual(blocks(1).startTime, 10);
            testCase.verifyEqual(blocks(1).endTime, 25);
        end
    end

    %% defineBlocks - Embed
    methods (Test)
        function testEmbedDefaultTrue(testCase)
            % Default behavior (Embed=true) returns data struct with .blocks
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            result = pf2.data.defineBlocks(data, 49, 20);

            testCase.verifyTrue(isfield(result, 'blocks'), ...
                'Default should embed blocks');
            testCase.verifyTrue(isfield(result, 'HbO'), ...
                'Should still be an fNIRS struct');
            testCase.verifyLength(result.blocks, 3);
        end

        function testEmbedBlocks(testCase)
            % Explicit Embed=true returns data struct with .blocks field
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            result = pf2.data.defineBlocks(data, 49, 20, 'Embed', true);

            testCase.verifyTrue(isstruct(result), 'Should return a struct');
            testCase.verifyTrue(isfield(result, 'blocks'), 'Should have .blocks field');
            testCase.verifyTrue(isfield(result, 'HbO'), 'Should still be an fNIRS struct');
            testCase.verifyLength(result.blocks, 3, 'Should have 3 blocks');
            testCase.verifyEqual(result.blocks(1).startTime, 30);
            testCase.verifyEqual(result.blocks(1).duration, 20);
        end

        function testEmbedFalseReturnBlocks(testCase)
            % Embed=false returns blocks array
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 49, 20, 'Embed', false);

            testCase.verifyFalse(isfield(blocks, 'HbO'), ...
                'Embed=false should return blocks, not data struct');
            testCase.verifyLength(blocks, 3);
        end

        function testEmbedWithConditionMap(testCase)
            % Embed works with ConditionMap and other options
            data = pf2_base.tests.unit.BlockDefinitionTest.makePairedMarkerData();
            result = pf2.data.defineBlocks(data, [50, 51], 10, ...
                'ConditionMap', {50, 'A'; 51, 'B'}, 'Embed', true);

            testCase.verifyTrue(isfield(result, 'blocks'));
            testCase.verifyLength(result.blocks, 4);
            testCase.verifyEqual(result.blocks(1).info.Condition, 'A');
        end

        function testDefineBlocksCellArray(testCase)
            % defineBlocks on cell array embeds blocks on each element
            data1 = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data1.info.SubjectID = 'S01';
            data2 = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data2.info.SubjectID = 'S02';

            allData = pf2.data.defineBlocks({data1, data2}, 49, 20);

            testCase.verifyTrue(iscell(allData), 'Should return cell array');
            testCase.verifyLength(allData, 2);
            testCase.verifyTrue(isfield(allData{1}, 'blocks'));
            testCase.verifyTrue(isfield(allData{2}, 'blocks'));
            testCase.verifyLength(allData{1}.blocks, 3);
            testCase.verifyEqual(allData{1}.info.SubjectID, 'S01');
        end
    end

    %% extractBlocks - Embedded Blocks
    methods (Test)
        function testExtractBlocksFromEmbed(testCase)
            % extractBlocks(data) finds data.blocks automatically
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data = pf2.data.defineBlocks(data, 49, 20, 'Embed', true);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, 'SetT0', false));

            testCase.verifyLength(segments, 3, 'Should extract 3 segments');
            testCase.verifyTrue(isfield(segments{1}, 'HbO'));
        end

        function testExtractBlocksExplicitStillWorks(testCase)
            % extractBlocks(data, blocks) still works as before
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 49, 20, 'Embed', false);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks, 'SetT0', false));

            testCase.verifyLength(segments, 3);
            testCase.verifyTrue(isfield(segments{1}, 'HbO'));
        end

        function testExtractBlocksNoBlocksError(testCase)
            % Error when no blocks provided and data.blocks missing
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            testCase.verifyError(...
                @() pf2.data.extractBlocks(data), ...
                'pf2:extractBlocks:noBlocks');
        end

        function testExtractBlocksCellArray(testCase)
            % Cell array of data structs with embedded blocks
            data1 = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data1.info.SubjectID = 'S01';
            data1 = pf2.data.defineBlocks(data1, 49, 20, 'Embed', true);

            data2 = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data2.info.SubjectID = 'S02';
            data2 = pf2.data.defineBlocks(data2, 49, 20, 'Embed', true);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks({data1, data2}, 'SetT0', false));

            testCase.verifyLength(segments, 6, 'Should have 3+3=6 segments');
            testCase.verifyEqual(segments{1}.info.SubjectID, 'S01');
            testCase.verifyEqual(segments{4}.info.SubjectID, 'S02');
        end

        function testExtractBlocksCellArrayWithNameValue(testCase)
            % Cell array with name-value params forwarded
            data1 = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data1 = pf2.data.defineBlocks(data1, 49, 20, 'Embed', true);

            segments = pf2.data.extractBlocks({data1}, ...
                'PreTime', 5, 'SetT0', true);

            testCase.verifyLength(segments, 3);
            testCase.verifyEqual(min(segments{1}.time), -5, 'AbsTol', 0.2);
        end

        function testSegmentsDontInheritBlocks(testCase)
            % Extracted segments should not carry parent .blocks
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data = pf2.data.defineBlocks(data, 49, 20, 'Embed', true);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data));

            testCase.verifyFalse(isfield(segments{1}, 'blocks'), ...
                'Individual segments should not have .blocks');
        end
    end

    %% Blocks propagation through data functions
    methods (Test)
        function testSetT0ShiftsBlockTimes(testCase)
            % setT0 should shift block start/end times
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data = pf2.data.defineBlocks(data, 49, 20, 'Embed', true);

            shifted = pf2.data.setT0(data, 10);

            testCase.verifyEqual(shifted.blocks(1).startTime, 20, ...
                'Block startTime should shift by -10');
            testCase.verifyEqual(shifted.blocks(1).endTime, 40, ...
                'Block endTime should shift by -10');
        end

        function testSplitFiltersBlocks(testCase)
            % split should keep only blocks within the time window
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data = pf2.data.defineBlocks(data, 49, 20, 'Embed', true);

            % Block times: [30-50, 90-115, 180-210]
            % Split to include only second block
            segment = pf2.data.split(data, 85, 120);

            testCase.verifyTrue(isfield(segment, 'blocks'), ...
                'split should preserve .blocks');
            testCase.verifyLength(segment.blocks, 1, ...
                'Only the block overlapping [85,120] should remain');
            testCase.verifyEqual(segment.blocks(1).startTime, 90);
        end

        function testBlocksPreservedThroughProcess(testCase)
            % processFNIRS2 should preserve .blocks on the output
            raw = pf2.import.sampleData.fNIR2000();

            % Add markers and define blocks before processing
            raw.markers = pf2_base.normalizeMarkers([30, 49, 20, 1; 90, 49, 20, 1]);
            raw = pf2.data.defineBlocks(raw, 49, 20, 'Embed', true);

            processed = processFNIRS2(raw);

            testCase.verifyTrue(isfield(processed, 'blocks'), ...
                'processFNIRS2 should preserve .blocks');
            testCase.verifyLength(processed.blocks, 2);
        end
    end

    %% extractBlocks - Buffer option
    methods (Test)
        function testBufferSymmetric(testCase)
            % Buffer applies to both pre and post sides
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            segments = pf2.data.extractBlocks(data, blocks, ...
                'Buffer', 5, 'SetT0', false);

            seg = segments{1};
            testCase.verifyLessThanOrEqual(min(seg.time), blocks(1).startTime - 5 + 0.2, ...
                'Buffer should extend pre side by 5 s');
            testCase.verifyGreaterThanOrEqual(max(seg.time), blocks(1).endTime + 5 - 0.2, ...
                'Buffer should extend post side by 5 s');
        end

        function testBufferOverriddenByExplicit(testCase)
            % Explicit PreTime overrides Buffer for the pre side; Buffer fills post
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 2, 'Buffer', 8, 'SetT0', false);

            seg = segments{1};
            testCase.verifyEqual(min(seg.time), blocks(1).startTime - 2, 'AbsTol', 0.2, ...
                'Explicit PreTime should win over Buffer');
            testCase.verifyEqual(max(seg.time), blocks(1).endTime + 8, 'AbsTol', 0.2, ...
                'Buffer should size the post side');
        end

        function testDefaultBufferWarningOnce(testCase)
            % With no window argument at all, the default-buffer note fires --
            % but only ONCE per session. Reset the function's persistent state
            % first so the test is independent of prior calls in the session.
            clear functions %#ok<CLFUNC>
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            % First call: the note fires.
            testCase.verifyWarning(...
                @() pf2.data.extractBlocks(data, blocks, 'SetT0', false), ...
                'pf2:extractBlocks:defaultBuffer');

            % Second call in the same session: suppressed (fires at most once).
            lastwarn('', '');
            pf2.data.extractBlocks(data, blocks, 'SetT0', false);
            [~, wid] = lastwarn();
            testCase.verifyNotEqual(wid, 'pf2:extractBlocks:defaultBuffer', ...
                'Default-buffer note should fire at most once per session.');
        end

        function testDefaultBufferIsTwoSeconds(testCase)
            % Default Buffer = 2 s on both sides when nothing is passed
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            segments = pf2_base.tests.unit.BlockDefinitionTest.suppressWarn(...
                @() pf2.data.extractBlocks(data, blocks, 'SetT0', false));

            seg = segments{1};
            testCase.verifyEqual(min(seg.time), blocks(1).startTime - 2, 'AbsTol', 0.3, ...
                'Default pre buffer should be 2 s');
            testCase.verifyEqual(max(seg.time), blocks(1).endTime + 2, 'AbsTol', 0.3, ...
                'Default post buffer should be 2 s');
        end

        function testExplicitNoDefaultBufferWarning(testCase)
            % Passing PreTime/PostTime suppresses the default-buffer note
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, 'Duration', 20, 'Embed', false);

            % No defaultBuffer warning when an explicit window is given. Use a
            % lastwarn-based check (verifyWarningFree would also flag unrelated
            % warnings such as channel-mask notices on this synthetic data).
            lastwarn('', '');
            pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 5, 'PostTime', 15, 'SetT0', false);
            [~, wid] = lastwarn();
            testCase.verifyNotEqual(wid, 'pf2:extractBlocks:defaultBuffer', ...
                'Explicit window should not emit the default-buffer note');
        end
    end

    %% defineBlocks - scalar marker-extra promotion
    methods (Test)
        function testScalarExtraPromotedToBlockInfo(testCase)
            % A single-valued marker extra column (e.g. RT) is promoted to info
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers.RT = [0.45; 0.62; 0.71];

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 5, 'Embed', false);

            testCase.verifyEqual(blocks(1).info.RT, 0.45, 'AbsTol', 1e-9);
            testCase.verifyEqual(blocks(2).info.RT, 0.62, 'AbsTol', 1e-9);
            testCase.verifyEqual(blocks(3).info.RT, 0.71, 'AbsTol', 1e-9);
        end

        function testScalarExtraSurvivesIntoSegmentInfo(testCase)
            % Promoted block.info extra survives into the extracted segment info
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers.RT = [0.45; 0.62; 0.71];

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 5, 'Embed', false);
            segments = pf2.data.extractBlocks(data, blocks, ...
                'PreTime', 1, 'PostTime', 1, 'SetT0', false);

            testCase.verifyEqual(segments{1}.info.RT, 0.45, 'AbsTol', 1e-9);
            testCase.verifyEqual(segments{2}.info.RT, 0.62, 'AbsTol', 1e-9);
        end

        function testExtraNotPromotedWhenInfoTableSetsIt(testCase)
            % An existing non-empty .info field is not overwritten by promotion
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers.RT = [0.45; 0.62; 0.71];
            rtTable = table([9; 9; 9], 'VariableNames', {'RT'});

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 5, 'InfoTable', rtTable, 'Embed', false);

            testCase.verifyEqual(blocks(1).info.RT, 9, ...
                'InfoTable value should take precedence over promotion');
        end

        function testPaddingDoesNotPullNeighborMarkerExtra(testCase)
            % With PrePad/PostPad widening the window, the default
            % MarkerWindow='core' must still attribute each block its OWN
            % per-trial extra (the pre-pad window), not a neighbour's, even when
            % the padded windows overlap the next onset.
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([
                30, 49, 10, 1;
                50, 49, 10, 1;   % only 10 s after block 1 ends -> pad overlaps
                70, 49, 10, 1;
            ]);
            data.markers.RT = [0.45; 0.62; 0.71];

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 10, 'PostPad', 15, 'Embed', false);

            testCase.verifyEqual(blocks(1).info.RT, 0.45, 'AbsTol', 1e-9, ...
                'Core window must not pull the neighbour''s RT into block 1.');
            testCase.verifyEqual(blocks(2).info.RT, 0.62, 'AbsTol', 1e-9);
            testCase.verifyEqual(blocks(3).info.RT, 0.71, 'AbsTol', 1e-9);
        end

        function testPaddedMarkerWindowSeesNeighborMarkers(testCase)
            % MarkerWindow='padded' deliberately uses the widened window: block 1
            % then spans block 2's onset, making RT multi-valued, so it does not
            % resolve to a scalar and is left unset. The final block (no later
            % neighbour) still promotes.
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([
                30, 49, 10, 1;
                50, 49, 10, 1;
                70, 49, 10, 1;
            ]);
            data.markers.RT = [0.45; 0.62; 0.71];

            blocks = pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 10, 'PostPad', 15, 'MarkerWindow', 'padded', ...
                'Embed', false);

            block1HasRT = isfield(blocks(1).info, 'RT') && ~isempty(blocks(1).info.RT);
            testCase.verifyFalse(block1HasRT, ...
                'Padded window should see two RTs for block 1 and skip promotion.');
            testCase.verifyEqual(blocks(3).info.RT, 0.71, 'AbsTol', 1e-9, ...
                'Final block has no later neighbour and should still promote.');
        end
    end

    %% defineBlocks - near-duplicate onset warning
    methods (Test)
        function testNearDuplicateOnsetWarning(testCase)
            % Two same-code markers within 0.05 s trigger a warning
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            data.markers = pf2_base.normalizeMarkers([
                30,    49, 10, 1;
                30.02, 49, 10, 1;   % near-duplicate of the first
                90,    49, 10, 1;
            ]);

            testCase.verifyWarning(...
                @() pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                    'Duration', 10, 'Embed', false), ...
                'pf2:defineBlocks:nearDuplicateOnsets');
        end

        function testNoNearDuplicateWarningWhenSpaced(testCase)
            % Well-separated markers do not trigger the warning
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            lastwarn('', '');
            pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                'Duration', 10, 'Embed', false);
            [~, wid] = lastwarn();
            testCase.verifyNotEqual(wid, 'pf2:defineBlocks:nearDuplicateOnsets', ...
                'Spaced markers should not emit the near-duplicate warning');
        end
    end

    %% Error Handling
    methods (Test)
        function testNoModeError(testCase)
            % Must specify either MarkerCode or StartMarker+EndMarker
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            testCase.verifyError(...
                @() pf2.data.defineBlocks(data, 'Duration', 10), ...
                'pf2:defineBlocks:noMode');
        end

        function testAmbiguousModeError(testCase)
            % Cannot specify both MarkerCode and StartMarker
            data = pf2_base.tests.unit.BlockDefinitionTest.makeSyntheticData();
            testCase.verifyError(...
                @() pf2.data.defineBlocks(data, 'MarkerCode', 49, ...
                    'StartMarker', 50, 'EndMarker', 51), ...
                'pf2:defineBlocks:ambiguousMode');
        end
    end
end
