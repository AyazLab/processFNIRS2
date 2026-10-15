function [sos, g] = zp2sos(z, p, k)
% ZP2SOS Zero-pole-gain to second-order sections (toolbox-free)
%
% Converts a zero-pole-gain filter description into a cascade of second-order
% sections (biquads). Clean-room reimplementation so the toolbox does not
% depend on the Signal Processing Toolbox; interface-compatible with the
% Signal Processing Toolbox ZP2SOS for the real-coefficient filters produced
% by pf2_base.external.butter. The overall transfer function of the returned
% cascade equals k * prod(z - zeros) / prod(z - poles).
%
% Reference:
%   Oppenheim, A. V. & Schafer, R. W. (2010). Discrete-Time Signal
%   Processing, 3rd ed. Prentice Hall. ISBN: 978-0131988422 (cascade
%   second-order-section realization of rational transfer functions).
%
% Syntax:
%   sos      = zp2sos(z, p, k)
%   [sos, g] = zp2sos(z, p, k)
%
% Inputs:
%   z - Zeros (vector, possibly complex; conjugate-symmetric for real filters).
%   p - Poles (vector, possibly complex; conjugate-symmetric for real filters).
%   k - Overall scalar gain.
%
% Outputs:
%   sos - [L x 6] matrix; row j is [b0 b1 b2 a0 a1 a2] for one biquad, with
%         a0 = 1. With one output argument the overall gain g is folded into
%         the first section's numerator.
%   g   - Overall gain. With two output arguments the sections are unscaled
%         (unit leading numerator where possible) and g carries the gain.
%
% Algorithm:
%   1. Split zeros and poles into second-order factors (conjugate pairs and
%      pairs of real roots) and at most one first-order factor (a lone real
%      root). Real filters from butter give matching first-order parities.
%   2. Match second-order pole factors with their nearest second-order zero
%      factors (by centroid distance) and the first-order pole factor with
%      the first-order zero factor, so every section's numerator and
%      denominator share the same order (a proper biquad / first-order
%      section). Pad any shortfall with all-pole (or all-zero) sections.
%   3. Expand each matched pair into coefficients; order sections with poles
%      closest to the unit circle last, and fold (or return) the overall gain.
%
% See also: butter, filtfilt_classic, pf2_bpf_butter, pf2_base.signal.bpf

z = z(:);
p = p(:);

[zQuad, zLin] = groupRoots(z);   % 2nd-order factors + (0 or 1) 1st-order
[pQuad, pLin] = groupRoots(p);

% Number of sections: one per quadratic factor (padded to match) plus one if
% either side has a lone first-order factor.
nQuad = max(numel(zQuad), numel(pQuad));
hasLin = ~isempty(zLin) || ~isempty(pLin);
% A first-order section must pair a lone real zero with a lone real pole. Real
% conjugate-symmetric filters (e.g. every pf2_base.external.butter output) give
% matching parities; a mismatch would mean an odd number of real roots on only
% one side, which cannot be realized as real second-order sections.
if hasLin && (isempty(zLin) || isempty(pLin))
    error('pf2_base:zp2sos:parityMismatch', ...
        ['Zeros and poles have mismatched real-root parity (one has a lone ', ...
         'real root, the other does not); cannot form real second-order ', ...
         'sections. Provide conjugate-symmetric z/p of matching parity.']);
end
L = nQuad + double(hasLin);

% Pad quadratic factor lists so both have nQuad entries (empty = order-0).
while numel(zQuad) < nQuad, zQuad{end+1} = zeros(0, 1); end %#ok<AGROW>
while numel(pQuad) < nQuad, pQuad{end+1} = zeros(0, 1); end %#ok<AGROW>

sos = zeros(L, 6);

% Pair each quadratic pole factor with its nearest quadratic zero factor,
% processing the poles CLOSEST to the unit circle first (Jackson's rule).
% The most resonant sections are the most sensitive, so they must claim their
% nearest zeros before the well-damped sections grab them; otherwise a high-Q
% pole can be left paired with a distant zero, giving that section a huge peak
% gain and overflowing the per-section filtfilt.
poleRadius = cellfun(@(r) maxRadius(r), pQuad);
[~, byProximity] = sort(poleRadius, 'descend');   % nearest unit circle first
matchZero = zeros(1, nQuad);                       % matchZero(poleIdx) = zeroIdx
zUsed = false(1, nQuad);
for t = 1:nQuad
    pj = byProximity(t);
    pr = pQuad{pj};
    bestIdx = 0;
    bestDist = inf;
    for ii = 1:nQuad
        if zUsed(ii), continue; end
        d = pairDistance(pr, zQuad{ii});
        if d < bestDist
            bestDist = d;
            bestIdx = ii;
        end
    end
    zUsed(bestIdx) = true;
    matchZero(pj) = bestIdx;
end

% Emit sections ordered by ascending pole radius (the default 'up' order, so
% the sections nearest |pole| = 1 come last).
[~, outOrder] = sort(poleRadius, 'ascend');
for row = 1:nQuad
    pj = outOrder(row);
    sos(row, :) = [padTo3(real(poly(zQuad{matchZero(pj)}(:).'))), ...
                   padTo3(real(poly(pQuad{pj}(:).')))];
end

% The lone first-order section pairs the linear zero with the linear pole.
if hasLin
    sos(L, :) = [padTo3(real(poly(zLin(:).'))), padTo3(real(poly(pLin(:).')))];
end

g = k;

if nargout < 2
    % Fold the overall gain into the first section's numerator.
    if L >= 1
        sos(1, 1:3) = g * sos(1, 1:3);
    end
end

end

%%_Subfunctions_____________________________________________________________

function [quad, lin] = groupRoots(r)
% GROUPROOTS Partition roots into 2nd-order factors plus a lone 1st-order one
%
% Inputs:
%   r - Root column vector (possibly complex, conjugate-symmetric).
%
% Outputs:
%   quad - Cell array; each cell holds the 2 roots of a second-order factor
%          (a conjugate pair, or two real roots).
%   lin  - The single leftover real root (empty if the real-root count is
%          even). Real Butterworth designs give matching parities for poles
%          and zeros, so the lone factors pair up.

quad = {};
lin = zeros(0, 1);
if isempty(r)
    return;
end

tol = 100 * eps(max(1, max(abs(r))));
isReal = abs(imag(r)) <= tol;

% Complex roots: keep those with positive imaginary part; pair with conjugate.
cpos = r(~isReal & imag(r) > 0);
% Ascending by real part, ties by imaginary part (MATLAB's
% 'ComparisonMethod','real'; written out because Octave's sort lacks it).
[~, ord] = sortrows([real(cpos(:)), imag(cpos(:))]);
cpos = cpos(ord);
for ii = 1:numel(cpos)
    quad{end+1} = [cpos(ii); conj(cpos(ii))]; %#ok<AGROW>
end

% Real roots: pair two at a time; a leftover singleton becomes the linear part.
rr = sort(real(r(isReal)), 'descend');
m = numel(rr);
ii = 1;
while ii + 1 <= m
    quad{end+1} = [rr(ii); rr(ii+1)]; %#ok<AGROW>
    ii = ii + 2;
end
if ii == m
    lin = rr(ii);   % one leftover real root
end

end

function d = pairDistance(a, b)
% PAIRDISTANCE Distance between two root-section centroids (empty-aware)
if isempty(a) || isempty(b)
    d = 1e6;   % defer empty matches
    return;
end
d = abs(mean(a) - mean(b));
end

function r = maxRadius(roots)
% MAXRADIUS Largest root magnitude in a section (0 for empty sections)
if isempty(roots)
    r = 0;
else
    r = max(abs(roots));
end
end

function c = padTo3(c)
% PADTO3 Right-pad a polynomial coefficient row to length 3
c = c(:).';
if numel(c) < 3
    c = [c, zeros(1, 3 - numel(c))];
end
end
