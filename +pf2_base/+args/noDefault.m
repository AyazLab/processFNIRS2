function s = noDefault()
% NODEFAULT Sentinel default for a name-value argument with no default
%
% Used in a pf2_base.args.parse spec to mark a name-value argument that
% should be absent from the returned opts struct unless the caller passes
% it, matching an arguments-block entry declared without a default.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   s = pf2_base.args.noDefault()
%
% Inputs:
%   (none)
%
% Outputs:
%   s - Sentinel struct recognised by pf2_base.args.parse.
%
% See also: pf2_base.args.parse

    s = struct('pf2ArgsNoDefault', true);
end
