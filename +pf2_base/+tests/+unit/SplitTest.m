classdef SplitTest < matlab.unittest.TestCase
    % SPLITTEST Unit tests for pf2.data.split
    %
    % Tests the time segmentation function including:
    %   - Basic time extraction (startTime, endTime)
    %   - segmentLength parameter
    %   - Relative vs absolute time modes
    %   - Baseline correction (blLength, blStartTime, blfNIR)
    %   - Marker filtering to extracted window
    %   - Field preservation (HbO, HbR, raw, etc.)
    %   - Edge cases and error conditions
    %
    % Run all tests:
    %   results = runtests('pf2_base.tests.unit.SplitTest');
    %
    % See also: pf2.data.split, pf2.data.resample, pf2.data.setT0

    properties
        processedData   % Processed fNIRS sample data
        rawData         % Raw (unprocessed) fNIRS sample data
    end

    methods (TestClassSetup)
        function loadSampleData(testCase)
            testCase.rawData = pf2.import.sampleData.fNIR2000();
            testCase.processedData = processFNIRS2(testCase.rawData);
        end
    end

    %% Basic Extraction Tests
    methods (Test)
        function testSplitStartTimeOnly(testCase)
            % Providing only startTime extracts from start to end

            timeVec = testCase.processedData.time;
            midTime = mean(timeVec);

            seg = pf2.data.split(testCase.processedData, midTime);

            testCase.verifyGreaterThanOrEqual(min(seg.time), midTime, ...
                'Segment should start at or after startTime');
            testCase.verifyEqual(max(seg.time), max(timeVec), 'AbsTol', 1/testCase.processedData.fs, ...
                'Segment should extend to end of recording');
        end

        function testSplitStartAndEndTime(testCase)
            % Providing startTime and endTime extracts that window

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 50;
            endT = min(timeVec) + 150;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyGreaterThanOrEqual(min(seg.time), startT, ...
                'Segment should start at or after startTime');
            testCase.verifyLessThanOrEqual(max(seg.time), endT, ...
                'Segment should end at or before endTime');
        end

        function testSplitReducesSamples(testCase)
            % Extracted segment should have fewer samples than original

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 50;
            endT = min(timeVec) + 100;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyLessThan(length(seg.time), length(timeVec), ...
                'Segment should have fewer samples than original');
        end

        function testSplitApproximateSampleCount(testCase)
            % Number of samples should match expected duration * fs

            fs = testCase.processedData.fs;
            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 20;
            duration = 60;  % 60 seconds
            endT = startT + duration;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            expectedSamples = duration * fs;
            actualSamples = length(seg.time);
            testCase.verifyEqual(actualSamples, expectedSamples, 'RelTol', 0.02, ...
                'Sample count should approximately match duration * fs');
        end
    end

    %% segmentLength Parameter Tests
    methods (Test)
        function testSegmentLength(testCase)
            % Using segmentLength instead of endTime

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            segLen = 40;

            seg = pf2.data.split(testCase.processedData, startT, nan, segLen);

            segDuration = max(seg.time) - min(seg.time);
            testCase.verifyEqual(segDuration, segLen, 'AbsTol', 1/testCase.processedData.fs, ...
                'Segment duration should match segmentLength');
        end
    end

    %% Relative Time Mode Tests
    methods (Test)
        function testRelativeTimeMode(testCase)
            % Relative mode equivalent: compute absolute times from offsets
            %
            % Since split() uses positional optionals, we test relative
            % behavior by computing absolute times manually.

            timeVec = testCase.processedData.time;
            relStart = 20;   % 20s from beginning
            relEnd = 80;     % 80s from beginning

            absStart = min(timeVec) + relStart;
            absEnd = min(timeVec) + relEnd;

            seg = pf2.data.split(testCase.processedData, absStart, absEnd);

            testCase.verifyGreaterThanOrEqual(min(seg.time), absStart, ...
                'Start should match expected absolute time');
            testCase.verifyLessThanOrEqual(max(seg.time), absEnd, ...
                'End should match expected absolute time');

            segDuration = max(seg.time) - min(seg.time);
            testCase.verifyEqual(segDuration, relEnd - relStart, ...
                'AbsTol', 1/testCase.processedData.fs, ...
                'Duration should match relative time span');
        end
    end

    %% Field Preservation Tests
    methods (Test)
        function testSplitPreservesOxyFields(testCase)
            % HbO, HbR, HbDiff, HbTotal, CBSI should all be extracted

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            endT = min(timeVec) + 90;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            oxyFields = {'HbO', 'HbR', 'HbDiff', 'HbTotal', 'CBSI'};
            for i = 1:length(oxyFields)
                f = oxyFields{i};
                testCase.verifyTrue(isfield(seg, f), ...
                    sprintf('%s field should be preserved', f));
                testCase.verifyEqual(size(seg.(f), 1), length(seg.time), ...
                    sprintf('%s rows should match time vector length', f));
            end
        end

        function testSplitPreservesChannelCount(testCase)
            % Number of channels should be unchanged

            origChannels = size(testCase.processedData.HbO, 2);
            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            endT = min(timeVec) + 90;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyEqual(size(seg.HbO, 2), origChannels, ...
                'Channel count should be preserved after split');
        end

        function testSplitPreservesMetadata(testCase)
            % Non-timeseries fields should be preserved

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            endT = min(timeVec) + 90;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            metaFields = {'info', 'fchMask', 'fs', 'channels'};
            for i = 1:length(metaFields)
                f = metaFields{i};
                if isfield(testCase.processedData, f)
                    testCase.verifyTrue(isfield(seg, f), ...
                        sprintf('%s should be preserved after split', f));
                end
            end
        end

        function testSplitPreservesFsUnchanged(testCase)
            % Sampling rate should not change

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 10;
            endT = min(timeVec) + 50;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyEqual(seg.fs, testCase.processedData.fs, ...
                'Sampling rate should be preserved after split');
        end
    end

    %% Baseline Correction Tests
    methods (Test)
        function testBaselineCorrectionSubtractsMean(testCase)
            % Baseline correction should subtract baseline mean from segment

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 20;
            endT = min(timeVec) + 100;
            blLen = 10;

            % Split without baseline
            segNoBL = pf2.data.split(testCase.processedData, startT, endT);

            % Split with baseline (positional args: startTime, endTime, segLen, relative, blLength)
            segLen = endT - startT;
            segBL = pf2.data.split(testCase.processedData, startT, endT, segLen, false, blLen);

            % Baseline-corrected data should differ from uncorrected
            testCase.verifyNotEqual(segBL.HbO, segNoBL.HbO, ...
                'Baseline correction should change HbO values');
        end

        function testBaselineCorrectionUsesExternalBaseline(testCase)
            % blfNIR parameter should use a separate struct for baseline

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 50;
            endT = min(timeVec) + 100;

            % Create a baseline from first 30s
            blStart = min(timeVec);
            blEnd = min(timeVec) + 30;
            blData = pf2.data.split(testCase.processedData, blStart, blEnd);

            % Split using external baseline
            seg = pf2.data.split(testCase.processedData, startT, endT, ...
                'blfNIR', blData);

            testCase.verifyTrue(isfield(seg, 'HbO'), ...
                'Should have HbO after split with external baseline');
            testCase.verifyEqual(size(seg.HbO, 2), size(testCase.processedData.HbO, 2), ...
                'Channel count should be preserved with external baseline');
        end
    end

    %% Marker Tests
    methods (Test)
        function testSplitFiltersMarkers(testCase)
            % Markers outside the split window should be removed

            % Add synthetic markers to data
            dataWithMarkers = testCase.processedData;
            timeVec = dataWithMarkers.time;
            minT = min(timeVec);

            dataWithMarkers.markers = pf2_base.normalizeMarkers([
                minT + 10, 1, 0, 1;   % Before split window
                minT + 60, 2, 0, 1;   % Inside split window
                minT + 70, 3, 0, 1;   % Inside split window
                minT + 200, 4, 0, 1;  % After split window
            ]);

            startT = minT + 50;
            endT = minT + 100;
            seg = pf2.data.split(dataWithMarkers, startT, endT);

            if isfield(seg, 'markers') && ~isempty(seg.markers)
                markerArray = pf2_base.markersToArray(seg.markers);
                if ~isempty(markerArray)
                    markerTimes = markerArray(:,1);
                else
                    markerTimes = [];
                end

                if ~isempty(markerTimes)
                    testCase.verifyGreaterThanOrEqual(min(markerTimes), startT, ...
                        'Markers before start should be removed');
                    testCase.verifyLessThanOrEqual(max(markerTimes), endT, ...
                        'Markers after end should be removed');
                end
            end
        end
    end

    %% Raw Data Tests
    methods (Test)
        function testSplitRawData(testCase)
            % Split should also work on raw (unprocessed) data

            timeVec = testCase.rawData.time;
            startT = min(timeVec) + 20;
            endT = min(timeVec) + 80;

            seg = pf2.data.split(testCase.rawData, startT, endT);

            testCase.verifyTrue(isfield(seg, 'raw'), ...
                'Raw field should be preserved');
            testCase.verifyTrue(isfield(seg, 'time'), ...
                'Time field should be preserved');
            testCase.verifyEqual(size(seg.raw, 1), length(seg.time), ...
                'Raw rows should match time vector length');
        end
    end

    %% Error and Edge Case Tests
    methods (Test)
        function testEndBeforeStartErrors(testCase)
            % endTime before startTime should error

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 100;
            endT = min(timeVec) + 50;

            testCase.verifyError(...
                @() pf2.data.split(testCase.processedData, startT, endT), ...
                'pf2:split:endBeforeStart', ...
                'End time before start time should error');
        end

        function testFullExtraction(testCase)
            % Extracting the full time range should preserve all data

            timeVec = testCase.processedData.time;
            startT = min(timeVec);
            endT = max(timeVec);

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyEqual(length(seg.time), length(timeVec), ...
                'Full extraction should preserve all samples');
        end

        function testSplitTimeVectorIsMonotonic(testCase)
            % Output time vector should be monotonically increasing

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            endT = min(timeVec) + 90;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            testCase.verifyTrue(all(diff(seg.time) > 0), ...
                'Output time vector should be monotonically increasing');
        end

        function testSplitDataValuesAreFromOriginal(testCase)
            % Extracted values should be exact copies from original

            timeVec = testCase.processedData.time;
            startT = min(timeVec) + 30;
            endT = min(timeVec) + 90;

            seg = pf2.data.split(testCase.processedData, startT, endT);

            % Find corresponding indices in original
            idxStart = find(testCase.processedData.time >= startT, 1);
            idxEnd = find(testCase.processedData.time <= endT, 1, 'last');
            expectedHbO = testCase.processedData.HbO(idxStart:idxEnd, :);

            testCase.verifyEqual(seg.HbO, expectedHbO, 'AbsTol', 1e-15, ...
                'Extracted HbO should exactly match original data slice');
        end

        function testAuxTableWithTimeColumn(testCase)
            % An aux signal stored as a table with its own time column
            % (e.g. a derived HRV series). Splitting and resampling rebuild
            % its time table, which R2025b's table() rejected when given a
            % single char variable name.
            data = testCase.processedData;
            t = (data.time(1):1:data.time(end))';
            data.Aux.hrv = table(t, 60 + randn(numel(t), 1), ...
                'VariableNames', {'time', 'RMSSD'});
            seg = pf2.data.split(data, data.time(1) + 20, data.time(1) + 80);
            testCase.verifyTrue(isfield(seg, 'Aux'), 'split dropped the Aux field');
            rs = pf2.data.resample(data, 0.5);
            testCase.verifyTrue(isfield(rs, 'Aux'), 'resample dropped the Aux field');
        end
    end
end
