function closeProgressHandles()
% CLOSEPROGRESSHANDLES Close all open progress bar figures
%
% Closes any progress status figures that have handles stored in the global
% variable ProgressHandles.h. Validates each handle before closing and
% removes invalid or closed handles from the structure. Initializes the
% ProgressHandles structure if it doesn't exist.
%
% Syntax:
%   closeProgressHandles()
%
% Inputs:
%   None - Reads from global variable ProgressHandles
%
% Outputs:
%   None - Closes figures and updates global ProgressHandles.h structure
%
% Example:
%   % After creating progress bars with stored handles
%   closeProgressHandles();  % Close all tracked progress figures
%
% See also: waitbar, close

global ProgressHandles

if(isempty(ProgressHandles))
        ProgressHandles.h=struct();
    return;
else
   validFields=fieldnames(ProgressHandles.h);
   
   for i=1:length(validFields)
        if(isvalid(ProgressHandles.h.(validFields{i})))
            close(ProgressHandles.h.(validFields{i}));
            ProgressHandles.h=rmfield(ProgressHandles.h,validFields{i});
        else
            ProgressHandles.h=rmfield(ProgressHandles.h,validFields{i});
        end
   end
    
end