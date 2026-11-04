classdef NirCounterTimebaseTest < matlab.unittest.TestCase
% NIRCOUNTERTIMEBASETEST Tests for the COBI .nir sample-counter time base
%
% Synthetic recordings with a known true sample time exercise
% pf2_base.nirCounterTimebase: the fitted counter tick, the latency-floor
% anchor, counter resets, PC clock restarts (carried by the counter), PC
% clock steps, delivery backlogs, counter pauses at dropouts, and the
% sampling rate. An end-to-end test writes a 2000M .nir file and imports
% it with pf2.import.importNIR.
%
% Usage:
%   results = runtests('pf2_base.tests.unit.NirCounterTimebaseTest');
%
% See also: pf2_base.nirCounterTimebase, pf2.import.importNIR

    methods (TestMethodSetup)
        function enableWarnings(testCase)
            % Other test classes may leave warnings off; these tests check them
            prev = warning;
            testCase.addTeardown(@() warning(prev));
            warning('on', 'all');
        end
    end

    methods (Test, TestTags = {'Import', 'NIR', 'Timebase'})
        function test2000MRecovery(testCase)
            % 2000M: 33/32768 s tick, 5 Hz, stamping jitter, stalls,
            % dropped samples, two counter resets with 2 s gaps and a PC
            % clock restart while the counter runs on
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 3600, ...
                'ResetsAt', [1200 2400], 'RestartAt', 3000, 'StallsAt', [100 300 1800 3100], ...
                'DropAt', 600);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', 'Model 2000M Imager');

            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01, ...
                'Event-time error should be 10 ms or less');
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 1e-3);
            testCase.verifyEqual(tb.pooledTick, 33/32768, 'RelTol', 1e-5);
            testCase.verifyEqual(tb.counterResets, 2);
            testCase.verifyEqual(tb.pcRestarts, 1);
            kinds = tb.gaps.Kind;
            testCase.verifyEqual(sum(strcmp(kinds, 'counter reset')), 2);
            testCase.verifyEqual(sum(strcmp(kinds, 'dropped samples')), 1);
            resetGaps = tb.gaps.Length(strcmp(kinds, 'counter reset'));
            testCase.verifyEqual(resetGaps, [2; 2], 'AbsTol', 0.01, ...
                'Reset gaps should keep their measured length');
            testCase.verifyEqual(sum(tb.pieces.DroppedSamples), 5);
            testCase.verifyTrue(all(diff(t) > 0));
        end

        function testOldMethodDrift2000M(testCase)
            % The previous 1 kHz counter assumption runs 0.7% fast on a
            % 2000M: about 25 s over an hour, and fs 5.025 Hz
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 3600);
            old = rec.pc(1) + (rec.counter - rec.counter(1)) / 1000;
            testCase.verifyGreaterThan(abs(old(end) - rec.truth(end)), 20);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 1e-3);
        end

        function test2000SUnchanged(testCase)
            % 2000S: 1 ms tick at 10 Hz. The fit returns 1 ms and the
            % times match the counter at 1 kHz within the stamping floor.
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 1800);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', 'Model 2000S HD');
            old = rec.pc(1) + rec.counter / 1000 - rec.counter(1) / 1000;   % previous importNIR arithmetic
            testCase.verifyEqual(tb.pooledTick, 1e-3, 'RelTol', 5e-6);
            testCase.verifyEqual(tb.fs, 10, 'AbsTol', 1e-4);
            testCase.verifyEqual(t, old, 'Times should be unchanged from the 1 kHz reading');
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testPCRestartsDuringBaseline(testCase)
            % PC clock restarts during the baseline: the PC column restarts
            % several times while the counter continues; one counter reset
            % falls where the PC clock is continuous. All times end up in the
            % final PC frame.
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 1500, ...
                'RestartAt', [55 80 120 180], 'ResetsAt', 100);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyEqual(tb.pcRestarts, 4);
            testCase.verifyEqual(tb.counterResets, 1);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyTrue(all(diff(t) > 0));
        end

        function testClockStepsFollowPC(testCase)
            % A PC clock that steps back 90 ms and later jumps ahead 70 ms
            % (time-sync corrections): the tick is still fitted correctly
            % and samples after the last change follow the PC clock
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 900);
            back = rec.truth >= 540;
            ahead = rec.truth >= 720;
            rec.pc(back) = rec.pc(back) - 0.090;
            rec.pc(ahead) = rec.pc(ahead) + 0.070;
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(tb.pcRestarts, 1);
            testCase.verifyEqual(tb.pcJumps, 1);
            testCase.verifyTrue(all(isnan(tb.pieces.FittedTick) | ...
                abs(tb.pieces.FittedTick / 1e-3 - 1) < 50e-6));
            final = rec.truth - 0.090 + 0.070;   % PC frame after the last change
            testCase.verifyLessThan(max(abs(t(ahead) - final(ahead))), 0.01);
        end

        function testBacklogIsNotSplit(testCase)
            % Delivery latency that grows to 30 s (a backlog) keeps the
            % counter timing in one piece; the latency is reported
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 1200);
            late = rec.truth > 900;
            rec.pc(late) = rec.pc(late) + 30 * ((rec.truth(late) - 900) / 300).^3;
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(height(tb.pieces), 1);
            testCase.verifyEqual(tb.pcJumps, 0);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyGreaterThan(max(tb.latency), 25);
        end

        function testCounterPauseAtDropout(testCase)
            % An 8 s outage across which the counter advances only 4 s: the
            % samples after it arrive 4 s later than the counter predicts,
            % so the gap comes from the PC clock
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 600, ...
                'DropAt', 300, 'DropCount', 40);
            after = rec.truth > rec.truth(1) + 300;   % truth starts at the PC clock origin
            rec.counter(after) = rec.counter(after) - round(4 / (33/32768));
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyEqual(tb.counterPauses, 1);
            testCase.verifyEqual(sum(strcmp(tb.gaps.Kind, 'counter pause')), 1);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testWrongModelWarns(testCase)
            % 2000M data read with the 1 ms default: the fitted tick is
            % used and the mismatch is warned
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 1200);
            [t, tb] = testCase.verifyWarning(@() pf2_base.nirCounterTimebase( ...
                rec.pc, rec.counter, 'Model', '2000S'), 'pf2:importNIR:tickMismatch');
            testCase.verifyEqual(tb.pooledTick, 33/32768, 'RelTol', 1e-5);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testImportNIR2000MFile(testCase)
            % End to end: a COBI Studio Modern 2000M .nir file imports with
            % fs = 5.000 Hz and the counter time base in info.timebase
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 900, 'ResetsAt', 500);
            fname = fullfile(folder, 'TB_999_200101_100000_Dev1_P1_Sub999.nir');
            testCase.writeNir(fname, rec, 60);

            prevGUI = pf2_base.channelCheckGUIEnabled(false);
            testCase.addTeardown(@() pf2_base.channelCheckGUIEnabled(prevGUI));
            data = pf2.import.importNIR(fname, false, false);
            testCase.verifyEqual(data.fs, 5, 'AbsTol', 1e-3);
            testCase.verifyTrue(isfield(data.info, 'timebase'));
            testCase.verifyEqual(data.info.timebase.counterResets, 1);
            testCase.verifyEqual(size(data.raw, 2), 55, 'Counter column should be dropped');
            testCase.verifyLessThan(max(abs(data.time - rec.truth)), 0.01);
        end
    end

    methods (Test, TestTags = {'Import', 'NIR', 'Timebase'})
        function test2000SSnapsToOneMillisecond(testCase)
            % A 1 ms counter whose fit is within 50 ppm keeps exactly 1 ms
            rec = testCase.synthRun('Tick', 1e-3 * (1 + 8e-6), 'Fs', 10, 'Duration', 1800);
            [~, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(tb.tick, 1e-3);
            testCase.verifyTrue(all(strcmp(tb.pieces.TickSource, 'snapped')));
            testCase.verifyEqual(tb.fs, 1 ./ median(diff(rec.pc(1) + rec.counter / 1000 - rec.counter(1) / 1000)));
        end

        function testShortFileWithoutModel(testCase)
            % A 300 s 2000M recording read without a model: the short fit
            % disagrees with 1 ms, is warned, and the 33/32768 s tick is used
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 300);
            [t, tb] = testCase.verifyWarning(@() pf2_base.nirCounterTimebase( ...
                rec.pc, rec.counter), 'pf2:importNIR:tickMismatch');
            testCase.verifyEqual(tb.tick, 33/32768);
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 2e-3);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testRestartWithCounterReset(testCase)
            % A PC restart at the same sample as a counter reset cannot be
            % linked: it is warned and time stays increasing
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 900, ...
                'ResetsAt', 400, 'RestartAt', 400);
            [t, tb] = testCase.verifyWarning(@() pf2_base.nirCounterTimebase( ...
                rec.pc, rec.counter, 'Model', '2000M'), 'pf2:importNIR:unlinkedRestart');
            testCase.verifyFalse(tb.frames.LinkedToNext(1));
            testCase.verifyTrue(all(diff(t) > 0));
            after = rec.truth >= rec.truth(find(diff(rec.pc) < -1, 1) + 1);
            testCase.verifyLessThan(max(abs(t(after) - rec.truth(after))), 0.01);
        end

        function testZeroAndNaNCounterRows(testCase)
            % Rows with a zero or NaN counter split the recording and are
            % timed from the PC column; the rest keep the counter timing
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 900);
            rec.counter(1:20) = 0;          % zero-padded baseline rows
            rec.counter(4000) = NaN;
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(sum(tb.noCounterRows), 21);
            testCase.verifyEqual(t(tb.noCounterRows), rec.pc(tb.noCounterRows));
            % The 1 ms piece is anchored at its first sample, as the earlier
            % 1 kHz reading was, so its error includes that sample's 3-33 ms
            % stamping delay
            ok = ~tb.noCounterRows;
            testCase.verifyLessThan(max(abs(t(ok) - rec.truth(ok))), 0.035);
        end

        function testDroppedSampleEpisodes(testCase)
            % Repeated dropouts, each preceded by a delivery-latency spike and
            % followed by a short backlog, are not counter pauses and leave
            % no short pieces
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 1800);
            keep = true(size(rec.pc));
            for st = 120:150:1700
                i = find(rec.truth >= rec.truth(1) + st, 1);
                rec.pc(i-5:i) = max(rec.pc(i-5:i), rec.pc(i-5) + 0.6);    % latency spike
                keep(i+1:i+4) = false;                                     % 4 samples dropped
                rec.pc(i+5:i+9) = rec.pc(i+5:i+9) + linspace(0.5, 0, 5)';  % backlog after reconnect
            end
            rec.pc = rec.pc(keep); rec.counter = rec.counter(keep); rec.truth = rec.truth(keep);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyEqual(tb.counterPauses, 0);
            testCase.verifyEqual(tb.pcJumps, 0);
            testCase.verifyEqual(height(tb.pieces), 1);
            testCase.verifyEqual(sum(strcmp(tb.gaps.Kind, 'dropped samples')), numel(120:150:1700));
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testFewerThanTwoRows(testCase)
            % Empty and single-row input return the PC times and no rate
            [t, tb] = pf2_base.nirCounterTimebase(zeros(0, 1), zeros(0, 1), 'Model', '2000S');
            testCase.verifyEmpty(t);
            testCase.verifyTrue(isnan(tb.fs));
            [t, tb] = pf2_base.nirCounterTimebase(12.5, 5000, 'Model', '2000S');
            testCase.verifyEqual(t, 12.5);
            testCase.verifyTrue(isnan(tb.fs));
        end

        function testCounterColumnDetection(testCase)
            % The sample-counter rule used by importNIR
            small = (1000:100:61000)';                       % 2000S, 60 s, still below 100000
            testCase.verifyTrue(pf2_base.isNirCounterColumn(small, '2000S'));
            testCase.verifyFalse(pf2_base.isNirCounterColumn(small, ''), ...
                'A small counter needs a known model');
            testCase.verifyFalse(pf2_base.isNirCounterColumn(small, '1200W'), ...
                '1200W files stay on the PC time column');
            big = (200000:199:400000)';
            testCase.verifyTrue(pf2_base.isNirCounterColumn([zeros(50, 1); big], ''), ...
                'Zero-padded baseline rows are ignored');
            testCase.verifyTrue(pf2_base.isNirCounterColumn([big(1:20); (37:199:60000)'; big], '2000M'), ...
                'An early counter reset is allowed');
            testCase.verifyFalse(pf2_base.isNirCounterColumn(round(2000 + 500 * rand(500, 1)), '2000S'), ...
                'An intensity column is not a counter');
        end

        function testMarkersAcrossRestart(testCase)
            % End to end: markers recorded in each PC frame are moved into
            % the final frame with the samples, and t0 moves with frame 1
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            % Frame 1 is long (PC 50-350 s); frames 2 and 3 restart near 0.
            % The marker file's order fixes the frames: each restart shows as
            % a drop in marker time
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 400, 'RestartAt', [300 330]);
            root = fullfile(folder, 'TB_999_200101_100000');
            testCase.writeNir([root '_Dev1_P1_Sub999.nir'], rec, 50);
            % One marker in each PC frame, at a sample's PC time
            k = [find(rec.truth >= rec.truth(1) + 150, 1), find(rec.truth >= rec.truth(1) + 325, 1), ...
                find(rec.truth >= rec.truth(1) + 340, 1)];
            testCase.writeMrk([root '_Mark1.mrk'], rec.pc(k) - 0.010, [11 12 13]);
            % Manual markers (<root>_C.mrk) are QPC times from the session
            % start (frame 1's clock, not reset by the restarts), written
            % with the header start code (40 s) added
            kManual = [find(rec.truth >= rec.truth(1) + 100, 1), find(rec.truth >= rec.truth(1) + 360, 1)];
            qpc = rec.truth(kManual) - rec.finalOrigin + rec.frame1Origin;
            fid = fopen([root '_C.mrk'], 'w');
            fprintf(fid, '%.3f\t%d\t0\tx\ty\r\n', [40 + qpc(:)'; 21 22]);
            fclose(fid);

            prevGUI = pf2_base.channelCheckGUIEnabled(false);
            testCase.addTeardown(@() pf2_base.channelCheckGUIEnabled(prevGUI));
            warnState = warning('off', 'pf2:importNIR:ambiguousMarkerFrame');
            testCase.addTeardown(@() warning(warnState));
            data = pf2.import.importNIR([root '_Dev1_P1_Sub999.nir'], true, false);
            testCase.verifyEqual(data.info.timebase.pcRestarts, 2);
            [~, order] = sort([11 12 13]);
            got = data.markers.Time(ismember(data.markers.Code, [11 12 13]));
            testCase.verifyEqual(numel(got), 3);
            expected = rec.truth(k(order));
            testCase.verifyLessThan(max(abs(got(:) - expected(:))), 0.06, ...
                'Markers should line up with their samples in the final PC frame');
            manual = data.markers.Time(ismember(data.markers.Code, [21 22]));
            expectedManual = rec.truth(kManual);
            testCase.verifyLessThan(max(abs(manual(:) - expectedManual(:))), 0.06, ...
                'Manual markers move by frame 1''s offset');
            % Header Start Time is the wall clock at PC time 0 of frame 1
            frame1Offset = data.info.timebase.frames.Offset(1);
            testCase.verifyLessThan(abs(seconds(data.t0 - ...
                (datetime(2020, 1, 1, 10, 0, 0) - seconds(frame1Offset)))), 1e-6);
        end

        function testShortCounterFileImports(testCase)
            % End to end: a 60 s 2000S file whose counter is below 100000
            % is still timed from the counter
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 60);
            fname = fullfile(folder, 'TB_999_200101_100000_Dev1_P1_Sub999.nir');
            testCase.writeNir(fname, rec, 50, '2000S');
            prevGUI = pf2_base.channelCheckGUIEnabled(false);
            testCase.addTeardown(@() pf2_base.channelCheckGUIEnabled(prevGUI));
            data = pf2.import.importNIR(fname, false, false);
            testCase.verifyTrue(isfield(data.info, 'timebase'));
            testCase.verifyEqual(size(data.raw, 2), 55);
        end

        function testFsOverrideOnlyWhileTimeMatches(testCase)
            % The counter rate applies while the time vector is the one it
            % was fitted on; after resampling the resampled rate is used
            data = pf2.import.sampleData.fNIR2000();
            testCase.assumeTrue(isfield(data.info, 'timebase'));
            testCase.verifyTrue(pf2_base.timebaseMatches(data, data.time));
            processed = processFNIRS2(data);
            testCase.verifyEqual(processed.fs, data.info.timebase.fs);
            resampled = pf2.data.resample(processed, 0.5);
            testCase.verifyFalse(pf2_base.timebaseMatches(resampled, resampled.time));
            reprocessed = processFNIRS2(resampled, 'None', 'LPF');
            testCase.verifyEqual(reprocessed.fs, 2, 'AbsTol', 1e-9);
        end
    end

    methods (Test, TestTags = {'Import', 'NIR', 'Timing'})
        function testIrregularPCTimingWarns(testCase)
            % PC-timed sampling with irregular 625-750 ms steps is warned
            % about; regular steps with a few dropouts are not
            prevRng = rng;
            testCase.addTeardown(@() rng(prevRng));
            rng(3);
            irregular = cumsum(0.625 + 0.125 * rand(500, 1));
            timing = testCase.verifyWarning(@() pf2_base.nirTimingCheck(irregular), ...
                'pf2:importNIR:irregularTiming');
            testCase.verifyTrue(timing.irregular);
            regular = cumsum(0.51 + 0.003 * randn(500, 1));
            regular(200:end) = regular(200:end) + 1.02;   % one dropout of two samples
            timing = testCase.verifyWarningFree(@() pf2_base.nirTimingCheck(regular));
            testCase.verifyFalse(timing.irregular);
            testCase.verifyEqual(timing.medianStep, 0.51, 'AbsTol', 0.005);
        end
    end

    methods (Test, TestTags = {'Processing', 'Timing'})
        function testNoTimeColumnWarnedOnce(testCase)
            % Device setup warns once per session that the raw data has no
            % time column (NIRx), not once per recording
            import matlab.unittest.constraints.IssuesWarnings
            clear('pf2_base.gui.updateCurrentDevice', 'pf2_base.pf2_updateCurrentDevice');
            prev = warning('on', 'pf2:updateCurrentDevice:noTimeColumn');
            testCase.addTeardown(@() warning(prev));
            data = testCase.syntheticNoTimeColumnData();
            id = 'pf2:updateCurrentDevice:noTimeColumn';
            testCase.verifyThat(@() processFNIRS2(data), IssuesWarnings({id}));
            % A second recording in the same session must not warn again: as
            % an error, the warning would stop processing
            warning('error', id); %#ok<WNTAG>
            processFNIRS2(data);
        end
    end

    methods (Test, TestTags = {'Import', 'NIR', 'Timebase', 'Review'})
        function testNoUsableCounterKeepsPCRate(testCase)
            % All counters zero or NaN: the PC times and their rate are kept
            pc = (0:299)' * 0.2 + 3;
            counter = zeros(300, 1);
            counter(100) = NaN;
            [t, tb] = pf2_base.nirCounterTimebase(pc, counter, 'Model', '2000M');
            testCase.verifyEqual(t, pc);
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 1e-9);
        end

        function testTimebaseMatchesSignature(testCase)
            % A same-length resample onto a regular grid at the median step
            % no longer matches; a shifted time vector (setT0) still does
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 600);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            data.info.timebase = tb;
            testCase.verifyTrue(pf2_base.timebaseMatches(data, t));
            testCase.verifyTrue(pf2_base.timebaseMatches(data, t - 12.5));
            regular = t(1) + (0:numel(t)-1)' * median(diff(t));
            testCase.verifyFalse(pf2_base.timebaseMatches(data, regular));
            testCase.verifyFalse(pf2_base.timebaseMatches(data, t(1:end-1)));
        end
    end

    methods (Access = private)
        function rec = synthRun(~, varargin)
            % SYNTHRUN Synthetic recording with known true sample times
            %   Counter resets restart the counter after a 2 s gap; PC
            %   restarts subtract the elapsed PC time; stalls hold samples
            %   for 0.3-0.9 s and deliver them together; DropAt removes
            %   DropCount samples (default 5, 1 s at 5 Hz).
            p = inputParser;
            p.addParameter('Tick', 1e-3);
            p.addParameter('Fs', 10);
            p.addParameter('Duration', 600);
            p.addParameter('ResetsAt', []);
            p.addParameter('RestartAt', []);
            p.addParameter('StallsAt', []);
            p.addParameter('DropAt', []);
            p.addParameter('DropCount', 5);
            p.parse(varargin{:});
            o = p.Results;
            prevRng = rng;
            rng(7);
            restoreRng = onCleanup(@() rng(prevRng));
            truth = (0:round(o.Duration * o.Fs) - 1)' / o.Fs;
            seg = ones(size(truth));
            for k = 1:numel(o.ResetsAt)
                seg = seg + (truth >= o.ResetsAt(k));
            end
            truth = truth + 2 * (seg - 1);
            counter = zeros(size(truth));
            for s = 1:max(seg)
                r = seg == s;
                counter(r) = 1000 * s + floor((truth(r) - truth(find(r, 1))) / o.Tick);
            end
            pc = 50 + truth + 0.003 + 0.030 * rand(size(truth));
            for st = o.StallsAt
                i = find(truth >= st, 1);
                L = 0.3 + 0.6 * rand;
                k = i:find(truth >= truth(i) + L, 1);
                pc(k) = max(pc(k), pc(i) + L);
            end
            final = 50;
            for k = 1:numel(o.RestartAt)
                after = truth >= o.RestartAt(k);
                shift = pc(find(after, 1)) - 0.2;
                pc(after) = pc(after) - shift;
                final = final - shift;
            end
            keep = true(size(truth));
            if ~isempty(o.DropAt)
                i = find(truth >= o.DropAt, 1);
                keep(i:i+o.DropCount-1) = false;
            end
            rec.pc = pc(keep);
            rec.counter = counter(keep);
            rec.truth = final + truth(keep);   % in the final PC frame
            rec.frame1Origin = 50;             % PC clock of the first frame at true time 0
            rec.finalOrigin = final;           % final PC frame at true time 0
        end

        function writeNir(~, fname, rec, nBaseline, model)
            % WRITENIR Write a COBI Studio Modern .nir file (time, 54
            % intensity columns, sample counter); the first nBaseline rows
            % form the baseline block
            if nargin < 5
                model = '2000M';
            end
            fid = fopen(fname, 'w');
            c = onCleanup(@() fclose(fid));
            nl = sprintf('\r\n');
            fprintf(fid, ['COBI Studio Modern Light Data File\t1.2.7654.28485' nl ...
                'Start Time:\tWed Jan 01 10:00:00.000 2020' nl ...
                'SubjectID:\t999\tData Source:\tDevice 1, Model ' model ' Imager, Port 1, HD, 18 optodes' nl ...
                'Start Code:\t1000000000000\t40000' nl 'Freq Code:\t10000000' nl ...
                'Current:\t30' nl 'Gains:\t5' nl 'Other:\tNone' nl ...
                '-2\tBaseline Started' nl]);
            vals = 1000 + round(500 * rand(numel(rec.pc), 54));
            row = @(i) [sprintf('%.3f', rec.pc(i)), sprintf('\t%d', vals(i, :)), ...
                sprintf('\t%d', rec.counter(i)), nl];
            for i = 1:nBaseline
                fprintf(fid, '%s', row(i));
            end
            fprintf(fid, ['-3\tBaseline values' nl '0' sprintf('\t%.2f', mean(vals(1:nBaseline, :))) nl ...
                '-4\tBaseline end' nl]);
            for i = nBaseline+1:numel(rec.pc)
                fprintf(fid, '%s', row(i));
            end
            fprintf(fid, ['-1\tDevice Stopped' nl]);
        end

        function data = syntheticNoTimeColumnData(~)
            % SYNTHETICNOTIMECOLUMNDATA A small NIRx-style recording (raw
            % data without a time column), imported from a synthetic .nirs
            folder = tempname;
            mkdir(folder);
            c = onCleanup(@() rmdir(folder, 's'));
            fid = fopen(fullfile(folder, 'rec.hdr'), 'w');
            fprintf(fid, '[GeneralInfo]\nDate="Wed, 01 Jan 2020"\nTime="10:00:00.000"\n\n[ImagingParameters]\nSamplingRate=7.812500\n');
            fclose(fid);
            t = (0:399)' / 7.8125; %#ok<NASGU>
            SD.Lambda = [760 850];
            SD.SpatialUnit = 'mm';
            SD.SrcPos = [0 0 0; 60 0 0; 30 30 5];
            SD.DetPos = [30 0 0; 0 30 5; 60 30 5; 38 30 5];
            sd = [1 1; 2 1; 1 2; 3 2; 3 3; 3 4];
            SD.MeasList = [sd ones(6, 1) ones(6, 1); sd ones(6, 1) 2 * ones(6, 1)]; %#ok<STRNU>
            d = 1 + 0.01 * rand(400, 12); %#ok<NASGU>
            s = zeros(400, 1); %#ok<NASGU>
            aux = zeros(400, 1); %#ok<NASGU>
            save(fullfile(folder, 'rec.nirs'), 't', 'd', 's', 'SD', 'aux');
            prevGUI = pf2_base.channelCheckGUIEnabled(false);
            restoreGUI = onCleanup(@() pf2_base.channelCheckGUIEnabled(prevGUI));
            data = pf2.import.importNIRX(fullfile(folder, 'rec.hdr'), false);
        end

        function writeMrk(~, fname, times, codes)
            % WRITEMRK Write a COBI Studio Modern marker file
            fid = fopen(fname, 'w');
            c = onCleanup(@() fclose(fid));
            nl = sprintf('\r\n');
            fprintf(fid, ['COBI Studio Modern Marker File\t1.2.7654.28485' nl ...
                'Listening Keyboard/Mouse\tMarker 1\tKeyboard/Mouse' nl ...
                'Start Time:\tWed Jan 01 10:00:00.000 2020' nl ...
                'Settings:\tColor: GreenYellow' nl ...
                'Start Code:\t1000000000000' nl 'Freq Code:\t10000000' nl]);
            for i = 1:numel(times)
                fprintf(fid, '%.3f\t%d\t1%s', times(i), codes(i), nl);
            end
        end
    end
end
