function [t, tb] = nirCounterTimebase(pc, counter, varargin)
% NIRCOUNTERTIMEBASE Sample times for a COBI .nir recording from its sample counter
%
% Builds the time vector of a COBI Studio Modern .nir recording from the
% device sample counter (last data column) and the PC time stamp (first
% column). Sample spacing comes from the counter, so PC stamping jitter and
% delivery stalls do not enter the time base; the counter tick and the
% absolute time come from the PC clock. The recording is split into pieces
% wherever the counter decreases (counter reset) or the PC time decreases
% by more than a second (PC clock restart). For each piece the counter tick b is fitted as the
% lower envelope of PC time against counter (the edge of the lower convex
% hull that spans the mean counter value), which follows the samples
% delivered with the least delay; ordinary least squares is tilted by
% stalls and the latency ramps that precede dropouts. Each piece is then
% anchored to its latency floor, A = min(PC - b*(counter - counter0)), and
% t = A + b*(counter - counter0). Pieces are not stitched end to end: each
% is placed on the PC clock by its own anchor, so gaps at counter resets
% keep their measured length. Across a PC clock restart the counter carries
% time from one PC frame to the next, and all times are expressed in the
% PC frame in force after the last restart.
%
% Reference:
%   Moon, S. B., Skelly, P., & Towsley, D. (1999). Estimation and removal of
%   clock skew from network delay measurements. IEEE INFOCOM '99, 227-234.
%   DOI: 10.1109/infcom.1999.749287
%
% Syntax:
%   [t, tb] = pf2_base.nirCounterTimebase(pc, counter)
%   [t, tb] = pf2_base.nirCounterTimebase(pc, counter, 'Model', '2000M')
%   [t, tb] = pf2_base.nirCounterTimebase(..., 'DefaultTick', 1e-3, 'MinFitSpan', 600)
%
% Inputs:
%   pc      - PC time stamp of each sample, in seconds [N x 1 double]
%   counter - Device sample counter of each sample [N x 1 double]. Rows
%             with a NaN or zero counter carry no counter information:
%             they split the recording, are kept, and are timed from the
%             PC column.
%
% Name-Value Parameters:
%   'Model'            - Device model text, e.g. '2000M' or 'Model 2000S
%                        Imager' (default: ''). Selects the default tick:
%                        33/32768 s for the 2000M, 1 ms otherwise.
%   'DefaultTick'      - Default counter tick in seconds; overrides Model
%                        (default: [] -> from Model).
%   'MinFitSpan'       - Shortest piece, in seconds, whose own fitted tick
%                        is used (default: 600). Shorter pieces use the
%                        span-weighted mean tick of the longer pieces, or
%                        the default tick when there are none.
%   'TickTolerancePPM' - Warn when a fitted tick differs from the default
%                        by more than this (default: 50).
%   'DropFactor'       - A counter step larger than this many median
%                        sample steps marks dropped samples (default: 1.5).
%   'RestartThreshold' - A PC time step back by more than this many
%                        seconds is a PC clock restart (default: 1). Smaller
%                        steps back are stamping jitter and stay in a piece.
%   'StepThreshold'    - A sustained shift of the PC latency floor larger
%                        than this (s) between StepWindow-long windows is a
%                        PC clock step (default: 0.05). A step back starts a
%                        new PC frame, like a restart; a jump ahead starts a
%                        new piece on the same PC clock, leaving a gap. The
%                        floor must be level over two windows on each side,
%                        so a delivery backlog does not count. The same
%                        threshold marks a counter pause at a dropout.
%   'StepWindow'       - Window length (s) for the latency floor (default: 30).
%
% Outputs:
%   t  - Sample times in seconds [N x 1], in the PC frame in force after
%        the last PC clock restart.
%   tb - Time-base QC struct:
%          .method        - 'counter'
%          .model         - Model text as given
%          .defaultTick   - Default tick (s)
%          .pooledTick    - Span-weighted mean fitted tick of pieces of at
%                           least MinFitSpan (NaN when there are none)
%          .fs            - Sampling rate: 1 / (tick * mean counts per sample)
%          .countsPerSample - Mean counter step between consecutive samples
%          .pieces        - Table, one row per piece: FirstRow, LastRow,
%                           CounterSegment, PCFrame, Tick, TickSource
%                           ('fit'|'pooled'|'default'), FittedTick,
%                           Anchor (s, own PC frame), FrameOffset (s),
%                           Span (s), LatencyP99, LatencyMax (s),
%                           DroppedSamples
%          .gaps          - Table: AfterRow, Start (s), Length (s), Kind
%                           ('counter reset'|'PC restart'|'PC step back'|
%                           'PC jump'|'counter pause'|'dropped samples'|
%                           'no counter')
%          .latency       - PC minus fitted time in the sample's own PC
%                           frame [N x 1] (s); link delivery delay
%          .pcTime        - The PC time column as recorded [N x 1] (s)
%          .noCounterRows - Logical [N x 1], rows timed from the PC column
%          .counterResets - Number of counter resets
%          .pcRestarts    - Number of PC clock restarts and steps back
%          .pcJumps       - Number of PC clock jumps ahead
%          .counterPauses - Number of dropouts through which the counter paused
%          .warnings      - Cell array of warning messages issued
%
% Algorithm:
%   1. Split into pieces at counter decreases, PC restarts, rows with a NaN
%      or zero counter, sustained steps of the PC latency floor (PC clock
%      adjustments), and dropouts through which the counter paused. Counter
%      steps above DropFactor x the median
%      step inside a piece are dropped samples; they are counted, and the
%      piece is kept.
%   2. Fit the tick per piece as the lower convex hull edge of PC against
%      counter spanning the mean counter value. Pieces of MinFitSpan or
%      more use their own tick; others the pooled tick or the default.
%   3. Anchor each piece to its latency floor and time it from the counter.
%   4. Express each PC frame in the final frame. Consecutive frames joined
%      by a continuous counter get the offset implied by the counter; a
%      restart that coincides with a counter reset cannot be linked and is
%      placed one sample after the previous frame (with a warning).
%
% Example:
%   [t, tb] = pf2_base.nirCounterTimebase(data(:,1), data(:,end), 'Model', '2000M');
%   fs = tb.fs;   % 5.000 Hz on a 2000M, where 1/median(diff(PC)) is not
%
% See also: pf2.import.importNIR

p = inputParser;
p.addParameter('Model', '', @(x) ischar(x) || isstring(x));
p.addParameter('DefaultTick', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && x > 0));
p.addParameter('MinFitSpan', 600, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.addParameter('TickTolerancePPM', 50, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.addParameter('DropFactor', 1.5, @(x) isnumeric(x) && isscalar(x) && x > 1);
p.addParameter('RestartThreshold', 1, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('StepThreshold', 0.05, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('StepWindow', 30, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.parse(varargin{:});
opts = p.Results;
model = char(opts.Model);

defaultTick = opts.DefaultTick;
if isempty(defaultTick)
    if contains(upper(model), '2000M')
        defaultTick = 33 / 32768;
    else
        defaultTick = 1e-3;
    end
end

pc = double(pc(:));
counter = double(counter(:));
N = numel(pc);
warnMsgs = {};

% --- 1. Pieces --------------------------------------------------------------
noCounter = isnan(counter) | counter == 0;
dc = diff(counter);
dpc = diff(pc);
counterBreak = dc < 0;
frameBreak = dpc < -opts.RestartThreshold;
breakAfter = counterBreak | frameBreak | noCounter(1:end-1) | noCounter(2:end);

% Sustained PC clock steps inside a piece: shifts of the latency floor
[stepBack, jumpAhead, counterPause] = findClockSteps(pc, counter, breakAfter, defaultTick, ...
    opts.StepWindow, opts.StepThreshold, opts.DropFactor);
% A floor step found at a counter pause is the same event; report it once
pauseRows = find(counterPause);
for i = pauseRows'
    jumpAhead(max(1, i-10):min(N-1, i+10)) = false;
end
frameBreak = frameBreak | stepBack;
breakAfter = breakAfter | stepBack | jumpAhead | counterPause;

starts = [1; find(breakAfter) + 1];
ends = [find(breakAfter); N];
nP = numel(starts);

% PC frame and counter segment of each piece
frameOfRow = 1 + [0; cumsum(frameBreak)];
segOfRow = 1 + [0; cumsum(counterBreak | noCounter(1:end-1) | noCounter(2:end))];
frame = frameOfRow(starts);
counterSeg = segOfRow(starts);
isCounterPiece = ~noCounter(starts);

% Typical counter step between samples
inPiece = ~breakAfter & dc > 0;
medStep = median(dc(inPiece));
if isempty(medStep) || isnan(medStep)
    medStep = 1;
end
normalStep = inPiece & dc <= opts.DropFactor * medStep;
countsPerSample = mean(dc(normalStep));
if isnan(countsPerSample)
    countsPerSample = medStep;
end
dropStep = inPiece & dc > opts.DropFactor * medStep;

% --- 2. Tick per piece ------------------------------------------------------
fittedTick = nan(nP, 1);
span = zeros(nP, 1);
for k = 1:nP
    r = starts(k):ends(k);
    if isCounterPiece(k)
        x = counter(r) - counter(starts(k));
        span(k) = x(end) * defaultTick;
        if numel(r) >= 3 && x(end) > 0
            fittedTick(k) = lowerHullSlope(x, pc(r));
        end
    else
        span(k) = pc(ends(k)) - pc(starts(k));
    end
end

isLong = isCounterPiece & span >= opts.MinFitSpan & ~isnan(fittedTick) & fittedTick > 0;
if any(isLong)
    pooledTick = sum(fittedTick(isLong) .* span(isLong)) / sum(span(isLong));
else
    pooledTick = NaN;
end

tick = nan(nP, 1);
tickSource = repmat({''}, nP, 1);
for k = 1:nP
    if ~isCounterPiece(k)
        tickSource{k} = 'none';
    elseif isLong(k)
        tick(k) = fittedTick(k);
        tickSource{k} = 'fit';
    elseif ~isnan(pooledTick)
        tick(k) = pooledTick;
        tickSource{k} = 'pooled';
    else
        tick(k) = defaultTick;
        tickSource{k} = 'default';
    end
end

ppm = abs(fittedTick(isLong) / defaultTick - 1) * 1e6;
if any(ppm > opts.TickTolerancePPM)
    msg = sprintf(['Fitted counter tick differs from the %s default (%.6g ms) by up to ' ...
        '%.0f ppm; check the device model.'], modelLabel(model), defaultTick * 1e3, max(ppm));
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:tickMismatch', '%s', msg);
end

% --- 3. Anchor each piece to its latency floor --------------------------------
tOwn = nan(N, 1);
anchor = nan(nP, 1);
for k = 1:nP
    r = starts(k):ends(k);
    if isCounterPiece(k)
        x = counter(r) - counter(starts(k));
        anchor(k) = min(pc(r) - tick(k) * x);
        tOwn(r) = anchor(k) + tick(k) * x;
    else
        anchor(k) = 0;
        tOwn(r) = pc(r);
    end
end
latency = pc - tOwn;

% --- 4. Express every PC frame in the final frame ----------------------------
nF = max(frameOfRow);
frameOffset = zeros(nF, 1);
period = defaultTick * countsPerSample;
if ~isnan(pooledTick)
    period = pooledTick * countsPerSample;
end
unlinked = 0;
for f = nF-1:-1:1
    % Piece pair across the restart from frame f to f+1
    kA = find(frame == f, 1, 'last');
    kB = find(frame == f + 1, 1, 'first');
    rB = starts(kB);
    if isCounterPiece(kA) && isCounterPiece(kB) && counterSeg(kA) == counterSeg(kB)
        % Counter continuous: time of rB in frame f, carried by the counter
        tInA = anchor(kA) + tick(kA) * (counter(rB) - counter(starts(kA)));
        d = tOwn(rB) - tInA;
    else
        % Restart coincides with a counter reset: no link between frames
        d = tOwn(rB) - (tOwn(ends(kA)) + period);
        unlinked = unlinked + 1;
    end
    frameOffset(f) = frameOffset(f + 1) + d;
end
t = tOwn + frameOffset(frameOfRow);

nPC = nF - 1;
if nPC > 0
    msg = sprintf(['The PC time column restarts or steps back %d time(s); time is carried ' ...
        'across by the sample counter. Times and markers use the PC frame in force ' ...
        'after the last restart.'], nPC);
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:pcRestart', '%s', msg);
end
if any(counterPause)
    msg = sprintf(['The sample counter paused through %d dropout(s) (samples after the ' ...
        'dropout arrive later than the counter predicts); each part is placed on the ' ...
        'PC clock.'], sum(counterPause));
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:counterPause', '%s', msg);
end
if any(jumpAhead)
    msg = sprintf(['The PC time column jumps ahead %d time(s) while the counter is ' ...
        'continuous; each part is placed on the PC clock, leaving a gap.'], sum(jumpAhead));
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:pcJump', '%s', msg);
end
if unlinked > 0
    msg = sprintf(['%d PC clock restart(s) coincide with a counter reset and cannot be ' ...
        'placed from the data; the earlier part is placed one sample before the restart.'], unlinked);
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:unlinkedRestart', '%s', msg);
end
if any(diff(t) <= 0)
    msg = sprintf('The counter time base is not increasing at %d sample(s).', sum(diff(t) <= 0));
    warnMsgs{end+1} = msg;
    warning('pf2:importNIR:nonMonotonicTime', '%s', msg);
end

% --- QC ------------------------------------------------------------------------
latP99 = nan(nP, 1);
latMax = nan(nP, 1);
dropped = zeros(nP, 1);
for k = 1:nP
    r = starts(k):ends(k);
    if isCounterPiece(k)
        lat = sort(latency(r));
        latP99(k) = lat(max(1, ceil(0.99 * numel(lat))));
        latMax(k) = max(latency(r));
        steps = dc(starts(k):ends(k)-1);
        drops = dropStep(starts(k):ends(k)-1);
        dropped(k) = sum(max(round(steps(drops) / countsPerSample) - 1, 0));
    end
end
pieces = table(starts, ends, counterSeg, frame, tick, tickSource, fittedTick, anchor, ...
    frameOffset(frame), span, latP99, latMax, dropped, ...
    'VariableNames', {'FirstRow', 'LastRow', 'CounterSegment', 'PCFrame', 'Tick', ...
    'TickSource', 'FittedTick', 'Anchor', 'FrameOffset', 'Span', 'LatencyP99', ...
    'LatencyMax', 'DroppedSamples'});

gapRow = [];
gapKind = {};
for k = 1:nP-1
    gapRow(end+1, 1) = ends(k); %#ok<AGROW>
    if ~isCounterPiece(k) || ~isCounterPiece(k+1)
        gapKind{end+1, 1} = 'no counter'; %#ok<AGROW>
    elseif stepBack(ends(k))
        gapKind{end+1, 1} = 'PC step back'; %#ok<AGROW>
    elseif frameBreak(ends(k))
        gapKind{end+1, 1} = 'PC restart'; %#ok<AGROW>
    elseif jumpAhead(ends(k))
        gapKind{end+1, 1} = 'PC jump'; %#ok<AGROW>
    elseif counterPause(ends(k))
        gapKind{end+1, 1} = 'counter pause'; %#ok<AGROW>
    else
        gapKind{end+1, 1} = 'counter reset'; %#ok<AGROW>
    end
end
dropRows = find(dropStep);
gapRow = [gapRow; dropRows];
gapKind = [gapKind; repmat({'dropped samples'}, numel(dropRows), 1)];
gapStart = t(gapRow);
gapLen = t(min(gapRow + 1, N)) - gapStart - period;
[gapRow, order] = sort(gapRow);
gaps = table(gapRow, gapStart(order), gapLen(order), gapKind(order), ...
    'VariableNames', {'AfterRow', 'Start', 'Length', 'Kind'});

bulkTick = pooledTick;
if isnan(bulkTick)
    bulkTick = defaultTick;
end

tb = struct();
tb.method = 'counter';
tb.model = model;
tb.defaultTick = defaultTick;
tb.pooledTick = pooledTick;
tb.fs = 1 / (bulkTick * countsPerSample);
tb.countsPerSample = countsPerSample;
tb.pieces = pieces;
tb.gaps = gaps;
tb.latency = latency;
tb.pcTime = pc;
tb.noCounterRows = noCounter;
tb.counterResets = sum(counterBreak);
tb.pcRestarts = nPC;
tb.pcJumps = sum(jumpAhead);
tb.counterPauses = sum(counterPause);
tb.warnings = warnMsgs;
end


function [stepBack, jumpAhead, counterPause] = findClockSteps(pc, counter, breakAfter, tick, win, thr, dropFactor)
% FINDCLOCKSTEPS Sustained shifts of the PC latency floor inside each piece
%   res = PC - tick*counter is the delivery latency plus a constant. Two
%   kinds of shift are split:
%   - A PC clock step: the floor (minimum of res over windows of win
%     seconds of counter time) moves by more than thr between adjacent
%     windows and is level (within thr/2) over two windows on each side.
%     A delivery backlog raises the floor window after window and is not
%     level, so it stays in the piece. The split is placed where the
%     samples cross the midpoint between the two floors.
%   - A counter pause: after dropped samples (a counter step above
%     dropFactor x the median step), the following samples arrive more
%     than thr later than the floor before the dropout predicts, so the
%     device counter did not advance through the whole outage.
%   Returns logical [N-1 x 1] masks (split after row k).
N = numel(pc);
stepBack = false(N - 1, 1);
jumpAhead = false(N - 1, 1);
counterPause = false(N - 1, 1);
starts = [1; find(breakAfter) + 1];
ends = [find(breakAfter); N];
dcAll = diff(counter);
medStep = median(dcAll(~breakAfter & dcAll > 0));
for k = 1:numel(starts)
    r = (starts(k):ends(k))';
    if numel(r) < 3 || any(isnan(counter(r))) || any(counter(r) == 0)
        continue;
    end
    tc = (counter(r) - counter(r(1))) * tick;     % counter time within the piece
    res = pc(r) - tc;

    % Counter pauses at dropouts
    dc = diff(counter(r));
    for i = find(dc > dropFactor * medStep)'
        pre = res(tc >= tc(i) - win & (1:numel(r))' <= i);
        post = res(i+1:min(i+10, numel(r)));
        if min(post) - min(pre) > thr
            counterPause(r(i)) = true;
        end
    end

    % PC clock steps with level floors on both sides
    nW = floor(tc(end) / win);
    if nW < 4
        continue;
    end
    w = min(floor(tc / win) + 1, nW);              % window of each sample
    fl = accumarray(w, res, [nW 1], @min, NaN);
    for j = 2:nW-2
        d = fl(j+1) - fl(j);
        if isnan(d) || abs(d) <= thr
            continue;
        end
        before = fl(j-1:j);
        after = fl(j+1:j+2);
        if range(before) > thr/2 || range(after) > thr/2
            continue;
        end
        region = find(w == j | w == j + 1);
        mid = (fl(j) + fl(j+1)) / 2;
        if d > 0
            % Jump ahead: split after the last low sample
            i = region(find(res(region) < mid, 1, 'last'));
            if ~isempty(i) && i < numel(r)
                jumpAhead(r(i)) = true;
            end
        else
            % Step back: split before the first low sample
            i = region(find(res(region) < mid, 1, 'first'));
            if ~isempty(i) && i > 1
                stepBack(r(i - 1)) = true;
            end
        end
    end
end
end


function v = range(x)
% RANGE Max minus min, ignoring NaN
v = max(x) - min(x);
end


function b = lowerHullSlope(x, y)
% LOWERHULLSLOPE Slope of the lower convex hull edge of (x, y) spanning mean(x)
%   The supporting line below all points that minimizes the summed vertical
%   distance passes through this edge (Moon, Skelly & Towsley, 1999).
[x, order] = sort(x);
y = y(order);
% Keep the lowest y for repeated x
[x, ~, grp] = unique(x);
y = accumarray(grp, y, [], @min);
n = numel(x);
if n < 2
    b = NaN;
    return;
end
hull = zeros(n, 1);
h = 0;
for i = 1:n
    while h >= 2 && cross2(x(hull(h-1)), y(hull(h-1)), x(hull(h)), y(hull(h)), x(i), y(i)) <= 0
        h = h - 1;
    end
    h = h + 1;
    hull(h) = i;
end
hull = hull(1:h);
xm = mean(x(grp));
e = find(x(hull(1:end-1)) <= xm & x(hull(2:end)) >= xm, 1);
if isempty(e)
    e = 1;
end
i1 = hull(e);
i2 = hull(e + 1);
b = (y(i2) - y(i1)) / (x(i2) - x(i1));
end


function c = cross2(x1, y1, x2, y2, x3, y3)
% CROSS2 z-component of (P2-P1) x (P3-P1); positive for a left turn
c = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
end


function s = modelLabel(model)
% MODELLABEL Short text naming the model in messages
if isempty(model)
    s = 'assumed';
else
    s = model;
end
end
