function tf = isNirCounterColumn(col, model)
% ISNIRCOUNTERCOLUMN True when the last .nir data column is the device sample counter
%
% COBI Studio Modern writes the device sample counter as the last column of
% a .nir file. The counter is a positive integer that rises at nearly every
% sample (a counter reset is allowed). Rows with a zero or NaN counter, such
% as a zero-padded baseline block, are ignored. Large values identify the
% counter on any device; on the models known to write it (2000M, 2000S,
% 3000C) a short recording whose counter is still small is recognised by a
% steady step of at least 10 counts. The 1200W counter is 16-bit and is not
% used: 1200W files stay on the PC time column.
%
% Syntax:
%   tf = pf2_base.isNirCounterColumn(col, model)
%
% Inputs:
%   col   - Last data column of the .nir file [N x 1 double]
%   model - Device model from the header Data Source line, e.g. '2000M'
%           (char; may be empty)
%
% Outputs:
%   tf - true when col should be read as the sample counter
%
% See also: pf2.import.importNIR, pf2_base.nirCounterTimebase

col = double(col(:));
model = char(model);
tf = false;
if contains(model, '1200')
    return;
end
c = col(col > 0 & ~isnan(col));
steps = diff(c);
if numel(steps) < 2 || any(c ~= round(c)) || mean(steps > 0) < 0.95
    return;
end
isCounterModel = any(contains(model, {'2000M', '2000S', '3000C'}));
tf = max(c) > 100000 || (isCounterModel && median(steps(steps > 0)) >= 10);
end
