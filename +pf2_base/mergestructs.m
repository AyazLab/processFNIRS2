function [structOut]=mergestructs (inputStruct1,inputStruct2,overwriteValues)
% MERGESTRUCTS Merge two structures with optional overwrite control
%
% Combines fields from two structures into a single output structure. By
% default, fields from the second structure overwrite matching fields in the
% first. Non-struct inputs are handled gracefully (returns the valid struct
% or the second input if neither is a struct).
%
% Syntax:
%   structOut = mergestructs(inputStruct1, inputStruct2)
%   structOut = mergestructs(inputStruct1, inputStruct2, overwriteValues)
%
% Inputs:
%   inputStruct1    - First structure to merge
%                     If not a struct, inputStruct2 is returned.
%   inputStruct2    - Second structure to merge
%                     Fields from this structure are added to structOut.
%                     If not a struct, inputStruct1 is returned unchanged.
%   overwriteValues - Logical scalar controlling overwrite behavior (default: true)
%                     true: Fields in inputStruct2 overwrite matching fields
%                           in inputStruct1.
%                     false: Only add fields from inputStruct2 that don't
%                            already exist in inputStruct1 (preserve original).
%
% Outputs:
%   structOut - Merged structure containing fields from both inputs
%               If overwriteValues=true: structOut = inputStruct1 + inputStruct2
%               If overwriteValues=false: structOut = inputStruct1, filled with
%               non-overlapping fields from inputStruct2.
%
% Algorithm:
%   1. Start with inputStruct1 as the base output
%   2. Iterate through all fields in inputStruct2
%   3. For each field, add or overwrite in structOut based on overwriteValues flag
%   4. Return merged structure
%
% Example:
%   % Basic merge with overwrite (default)
%   s1 = struct('a', 1, 'b', 2);
%   s2 = struct('b', 20, 'c', 3);
%   merged = mergestructs(s1, s2);  % merged.a=1, merged.b=20, merged.c=3
%
%   % Merge without overwrite (preserve original values)
%   merged = mergestructs(s1, s2, false);  % merged.a=1, merged.b=2, merged.c=3
%
%   % Merge processing metadata
%   data.info = struct('SubjectID', 'S01', 'Age', 25);
%   newInfo = struct('Age', 30, 'Session', 1);
%   data.info = mergestructs(data.info, newInfo);  % Age updated to 30, Session added
%
% See also: struct, fieldnames, isfield

if(nargin<3)
    overwriteValues=true;
end


structOut=inputStruct1;

if(~isstruct(inputStruct2))
    return;
end

if(~isstruct(inputStruct1))
    structOut=inputStruct2;
end

structFields2=fieldnames(inputStruct2);

numFields = length(structFields2);

for i=1:numFields

    curVariableName = structFields2{i};
    
    if(~overwriteValues)
        if(isfield(inputStruct1,curVariableName))
            continue;
        end
    end
        
    structOut.(curVariableName)=inputStruct2.(curVariableName);
end