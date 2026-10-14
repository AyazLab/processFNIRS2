function [] = temporal(gbyData,gbyVars,exSettings, handles)
% TEMPORAL Plot time-series data from exploreFNIRS grouped analysis
%
% Creates temporal (time-course) plots for fNIRS biomarker data, showing
% the hemodynamic response over time for selected channels and conditions.
% Supports multiple grouping variables, error shading, and marker overlays.
%
% Reference:
%   Internal exploreFNIRS visualization. Shaded error regions are drawn
%   with native MATLAB patch/fill primitives.
%
% Syntax:
%   temporal(gbyData, gbyVars, exSettings, handles)
%
% Inputs:
%   gbyData    - Cell array of grouped data from exploreFNIRS analysis
%                Each cell contains data for one group/condition
%   gbyVars    - Cell array of grouping variable names used in analysis
%                e.g., {'Subject', 'Condition', 'Block'}
%   exSettings - Structure of exploreFNIRS settings including:
%                .curInfoGroup  - Current info grouping variable
%                .ChannelMode   - 'Channel', 'ROI', or 'Aux'
%                .showMarkers   - Display event markers
%                .errorType     - 'SEM', 'STD', or 'CI'
%   handles    - GUI handles structure from exploreFNIRS containing:
%                .listbox_biomarker - Selected biomarkers
%                .listbox_optode    - Selected channels/optodes
%                .axes_temporal     - Target axes for plotting
%
% Outputs:
%   None (creates figure/updates axes)
%
% Plot Features:
%   - Mean time-course with shaded error regions
%   - Multiple biomarkers (HbO, HbR, etc.) on same axes
%   - Condition comparison with different colors
%   - Event marker overlay from experimental design
%   - Automatic legend generation
%
% Notes:
%   - Typically called from exploreFNIRS GUI, not directly
%   - Draws shaded error bands with native MATLAB patch/fill
%   - Supports hierarchical averaging within subjects
%
% See also: exploreFNIRS.plot.barchart, exploreFNIRS.plot.scatter

curInfoGroup=exSettings.curInfoGroup;


if(~isempty(curInfoGroup)&&~strcmp(curInfoGroup,'(Time)'))
    [ismem,idx]=ismember(curInfoGroup,gbyVars);
    if(ismem)
        gbyVars(idx)=[];
        useCurInfoGroup=true;
    else
        useCurInfoGroup=false;
    end
else
    useCurInfoGroup=false;
end


numGroups=length(gbyData);

biomStrs=get(handles.listbox_biomarker,'String');
selBioM=get(handles.listbox_biomarker,'Value');
selectedBioM=biomStrs(selBioM);
numBioM=length(selBioM);



optStrs=cellstr(get(handles.listbox_optode,'String'));
selOpt=get(handles.listbox_optode,'Value');
selectedOptStr=optStrs(selOpt);

if(strcmp(exSettings.ChannelMode,'Aux'))
    if(length(selectedBioM)>1)
        error('exploreFNIRS:plot:temporal:notSupported', 'Not supported yet!')
    end
    auxTable=get(handles.listbox_optode,'UserData');
    selectedOpt=nan(length(selOpt));
    for sI=1:length(selOpt)
        selectedOpt(sI)=auxTable{selectedBioM,selectedOptStr{sI}};
    end
    
else
    selectedOpt=selOpt;
end


numOpt=length(selectedOpt);

if(numOpt==0||numGroups==0||numBioM==0)
    return;
end

if(exSettings.ylim_fixed)
    exSettings.ylim_fixed_min=inf;
    exSettings.ylim_fixed_max=-inf;
end

curInfoGby=cell(0);
gbyStrs=cell(1,numGroups);

for g=1:numGroups
    gbyStrs{g}='';
   if(~isempty(gbyData(g).gbyTables))
       for i=1:length(gbyVars)
           gbyStrs{g}=sprintf('%s%s:%s,',gbyStrs{g},gbyVars{i},num2strOrNot(gbyData(g).gbyTables.(gbyVars{i})(1)));
       end 
       if(useCurInfoGroup)
           curInfoGby{g}=num2strOrNot(gbyData(g).gbyTables.(curInfoGroup)(1));
       end
   end 
   if(~isempty(gbyStrs{g}))
        gbyStrs{g}(end)='';
   end
end

[uCurInfoG,firstCurIdx,uCurIdx]=unique(cellstr(curInfoGby));

numCurInfoG=length(uCurInfoG);

numUgroups=length(unique(cellstr(gbyStrs)));

uCurGIdxCount=nan(size(uCurIdx));
for i =1:numCurInfoG
    uCurGIdxCount(uCurIdx==i)=1:sum(uCurIdx==i);
end

if(numUgroups==1)
    num2Plot=numBioM;
    plotGroupByBioM=true;
    bioColorTable=table2cell(pf2_base.getBioColors());
    cIndex=[];
    for i=1:length(bioColorTable)
        cIndex(i,:)=bioColorTable{i};
    end
else
    num2Plot=numUgroups;
    plotGroupByBioM=false;
    if(exSettings.use_gui_color)
        cIndex=exSettings.guiColor(1:numUgroups,:);
    else
        cIndex=exSettings.cmap(numUgroups);%linspecer(num2Plot,'qualitative');
    end
end


errorFeature=exSettings.plot_error_feature;
errMulitply=exSettings.plot_error_multiply;
plotFeature=exSettings.plot_grandaverage_feature;

if(strcmp(plotFeature,'Count')&&exSettings.plot_grandaverage)
  plotFeature='N';
  plotCount=true;
else
    plotCount=false;
end


if(~plotGroupByBioM)
    if(numOpt>1&&numCurInfoG>1)
        xType='channels';
        yType='groupby';
        figType='bioM';
        numSubX=numOpt;
        numSubY=numCurInfoG;
    elseif(numOpt==1&&numCurInfoG>1)
        xType='bioM';
        yType='groupby';
        figType='';
        numSubX=numBioM;
        numSubY=numCurInfoG;
    elseif(numCurInfoG<=1&&numOpt>1)
        xType='channels';
        yType='bioM';
        figType='';
        numSubX=numOpt;
        numSubY=numBioM;
    else
        xType='bioM';
        yType='';
        figType='';
        numSubX=numBioM;
        numSubY=1;
    end
else %plot with biomarkers embedded
    if(numOpt>=1&&numCurInfoG>1)
        xType='channels';
        yType='groupby';
        figType='';
        numSubX=numOpt;
        numSubY=numCurInfoG;
    elseif(numCurInfoG<=1&&numOpt>1)
        xType='channels';
        yType='';
        figType='';
        numSubX=numOpt;
        numSubY=1;
    else
        xType='';
        yType='';
        figType='';
        numSubX=1;
        numSubY=1;
    end
end



switch(figType)
    case 'bioM'
        for i=1:numBioM
            sH{i,1}.h=figure(900+i);
            clf(sH{i,1}.h);
            dcm_obj = datacursormode(sH{i,1}.h);
            set(dcm_obj,'UpdateFcn',@myDataTipUpdateFcn);
            for s=1:(numSubX*numSubY)
                xInd=rem(s,numSubX);
                if(xInd==0)
                    xInd=numSubX;
                end
                h=subplot(numSubY,numSubX,s,'Parent',sH{i,1}.h);
                if(exSettings.plot_temporal_y0)
                    yh=plot([exSettings.plot_start,exSettings.plot_end],[0,0],'k');
                    set(yh,'HandleVisibility','off');
                end
                sH{i,1}.subH{floor((s-1)/numSubX)+1,xInd}=h;
                legend(h, 'off');
            end
            multiPlot=true;
        end
    otherwise
        sH{1,1}.h=figure(900);
        clf(sH{1,1}.h);
        dcm_obj = datacursormode(sH{1,1}.h);
        set(dcm_obj,'UpdateFcn',@myDataTipUpdateFcn);
        for s=1:(numSubX*numSubY)
            xInd=rem(s,numSubX);
            if(xInd==0)
                xInd=numSubX;
            end
            h=subplot(numSubY,numSubX,s);
            if(exSettings.plot_temporal_y0)
                yh=plot([exSettings.plot_start,exSettings.plot_end],[0,0],'k');
                set(yh,'HandleVisibility','off');
            end
            sH{1,1}.subH{floor((s-1)/numSubX)+1,xInd}=h;
            legend(h, 'off');
        end
        multiPlot=false;
end

curSx=1;
curSy=1;
curFigIdx=[1,1];

for chIdx=1:numOpt
    ch=selectedOpt(chIdx);
    if(isnan(ch))
        warning('Channel is Nan, variable may not exist in array/table');
        continue;
    end
    gStrs=cell(num2Plot,1);
    for b=1:numBioM
        bioM=selectedBioM(b);
        if(iscell(bioM))
            bioM=bioM{1};
        end
        
        if(~plotGroupByBioM)
            gStrs=cell(num2Plot,1);
        end
        
        hGrandErr1=cell(num2Plot,1);
        hGrandErr2=cell(num2Plot,1);
        
        for g=1:numGroups
            if(useCurInfoGroup)
                curGroupInfoIdx=uCurIdx(g);
                curUgroupIdx=uCurGIdxCount(g);
            else
                curGroupInfoIdx=1;
                curUgroupIdx=g;
            end
            
            
            if(strcmp(figType,'bioM'))
                curFigH=sH{b,1};
            else
               curFigH=sH{1,1}; 
            end
            
            switch(xType)
                case 'channels'
                    curSx=chIdx;
                case 'bioM'
                    curSx=b;
                case 'groupby'
                    curSx=curGroupInfoIdx;
            end
                
            switch(yType)
                case 'channels'
                    curSy=chIdx;
                case 'bioM'
                    curSy=b;
                case 'groupby'
                    curSy=curGroupInfoIdx;
            end
            
            if(curSy==numSubY&&curSx==numSubX)
                lastSubplot=true;
            else
                lastSubplot=false;
            end
            
            curFNIRS=gbyData(g).gbyFNIRS;
            curGrand=gbyData(g).gbyGrand;
            
            
            hold(curFigH.subH{curSy,curSx},'on');
            if(exSettings.plot_individual&&~plotCount)
               for i=1:length(curFNIRS)
                   if(~isfield(curFNIRS{i},'HbO'))
                       continue;
                   end
                   if(~isfield(curFigH,'legendHandles'))
                       if(plotGroupByBioM)
                            curFigH.legendHandles{curSy,curSx}.h=cell(numBioM,1);
                       else
                           curFigH.legendHandles{curSy,curSx}.h=cell(numUgroups,1);
                       end
                   end

                   
                   
                   switch exSettings.ChannelMode
                       case 'fNIR'
                           data2plot=curFNIRS{i};
                           dataTime=curFNIRS{i}.time;
                       case 'ROI'
                           if(~pf2_base.isnestedfield(curGrand,'ROI.HbO.data'))
                              error('exploreFNIRS:plot:temporal:roiNotBuilt', 'ROI data must be calculated using a build ROI step');
                           end
                          if(~isempty(curFNIRS{i})&&isfield(curFNIRS{i},'ROI'))
                            data2plot=curFNIRS{i}.ROI;
                          else
                             data2plot=[]; 
                          end
                          dataTime=curFNIRS{i}.time;
                          
                       case 'Aux'
                           data2plot=curFNIRS{i}.Aux;
                           if(pf2_base.isnestedfield(data2plot.(bioM),'time')) %otherwise use aux time
                               if(istable(data2plot.(bioM)))
                                    dataTime=data2plot.(bioM).time;
                                    data2plot.(bioM).time=[];
                                    
                                    %=data2plot.(bioM).Properties.VariableNames;
                                    %timeIdx=ismember(varNames,'time');
                                    %data2plot.(bioM)=data2plot.(bioM)(:,~timeIdx);
                                    %data2plot.(bioM)=data2plot.(bioM){:,ch}; 

                                
                               else
                                     dataTime=data2plot.(bioM).time;
                                     varNames=fieldnames(data2plot.(bioM));
                                     timeIdx=ismember(varNames,'time');
                                     firstVar=find(~timeIdx);
                                     data2plot.(bioM)=data2plot.(bioM).(varNames{firstVar(1)});
                               end
                               
                           elseif(isfield(data2plot,bioM)&&size(data2plot.(bioM),2)>1) %if has its own time use that
                               dataTime=data2plot.(bioM)(:,1);
                               data2plot.(bioM)=data2plot.(bioM)(:,2); 
                           elseif(isfield(data2plot,'time'))
                               dataTime=data2plot.time;  %or fnirs time
                           else
                               dataTime=curFNIRS{i}.time;  %or fnirs time
                           end
                           
                   end

                   if(isfield(data2plot,bioM))
                    plotAsTable=istable(data2plot.(bioM));
                   else
                    plotAsTable=false;
                   end
                   
                  if(plotGroupByBioM)
                      if(~isempty(data2plot)&&isfield(data2plot,bioM))
                          if(~plotAsTable)
                              try
                            h=plot(curFigH.subH{curSy,curSx},dataTime,data2plot.(bioM)(:,ch),'color',cIndex(b,:));
                              catch
                                  x=1;
                              end
                          else
                            h=plot(curFigH.subH{curSy,curSx},dataTime,data2plot.(bioM){:,ch},'color',cIndex(b,:));
                          end
                          set(h,'Tag',getFormattedTrialString(curFNIRS{i}));
                          if(exSettings.plot_grandaverage||~isempty(curFigH.legendHandles{curSy,curSx}.h{b}))
                            set(h.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                          end
                          gStrs{b}=selectedBioM{b};
                          curFigH.legendHandles{curSy,curSx}.h{b}=h;
                      end
                  else
                      if(isfield(data2plot,bioM)&&~isempty(data2plot.(bioM)))
                          if(~plotAsTable)
                            h=plot(curFigH.subH{curSy,curSx},dataTime,data2plot.(bioM)(:,ch),'color',cIndex(curUgroupIdx,:));
                          else
                            h=plot(curFigH.subH{curSy,curSx},dataTime,data2plot.(bioM){:,ch},'color',cIndex(curUgroupIdx,:));
                          end
                          set(h,'Tag',getFormattedTrialString(curFNIRS{i}));

                          if(exSettings.plot_grandaverage||~isempty(curFigH.legendHandles{curSy,curSx}.h{curUgroupIdx}))
                              if(~isempty(h))
                                 set(h.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                              end
                          end
                          gStrs{curUgroupIdx}=gbyStrs{g}; 
                          curFigH.legendHandles{curSy,curSx}.h{curUgroupIdx}=h;
                      end
                  end
                  
                  
                  
                  hold on;
               end
            end

            if(exSettings.plot_grandaverage)
                  switch(exSettings.ChannelMode)
                      case 'fNIR'
                          data2plot=curGrand.(bioM);
                      case 'ROI'
                          if(~pf2_base.isnestedfield(curGrand,'ROI.HbO.data'))
                              warning('ROI data must be calculated using a build ROI step');
                              data2plot=[];
                          else
                            data2plot=curGrand.ROI.(bioM);
                          end
                      case 'Aux'
                            data2plot=curGrand.Aux.(bioM);
                            %if(ndims(data2plot)>1)
                            %    data2plot=data2plot(:,2);
                            %end
                            
                  end
                  
                  
                  if(~isempty(data2plot))
                      if(plotGroupByBioM)
                          hGrand=plot(curFigH.subH{curSy,curSx},curGrand.time,data2plot.(plotFeature)(:,ch),'LineWidth',3,'color',cIndex(b,:));
                      else
                          hGrand=plot(curFigH.subH{curSy,curSx},curGrand.time,data2plot.(plotFeature)(:,ch),'LineWidth',3,'color',cIndex(curUgroupIdx,:));
                      end

                      if(numUgroups>1||numBioM==1)&&~isempty(gbyStrs{g})
                           gStrs{curUgroupIdx}=gbyStrs{g}; 
                           set(hGrand,'Tag',sprintf('%s: %s',plotFeature,gStrs{curUgroupIdx}));
                           curFigH.legendHandles{curSy,curSx}.hG{curUgroupIdx}=hGrand;
                      elseif(~multiPlot)
                           gStrs{b}=selectedBioM{b};
                           set(hGrand,'Tag',sprintf('%s: %s',plotFeature,gStrs{b}));
                           curFigH.legendHandles{curSy,curSx}.hG{b}=hGrand;
                      end
                  end
                  
                  
            end
            
            if(exSettings.plot_error&&~plotCount)
                errStyle=exSettings.plot_error_style;
                plotShaded=false;
                
                switch(errStyle)
                    case 'Dashed'
                        errStyle='--';
                        lineWidth=2;
                    case 'Fine'
                        errStyle='-';
                        lineWidth=0.5;
                    case 'Shaded'
                        errStyle='-';
                        lineWidth=0.5;
                        plotShaded=true;
                    otherwise
                        errStyle='-';
                        lineWidth=0.5;
                        plotShaded=true;
                        %error('Unspecified error style');
                end
                     
                if(plotGroupByBioM)
                    errColor=cIndex(b,:);
                    errColor=errColor+(1-errColor)*0.55;
                else
                    errColor=cIndex(curUgroupIdx,:);
                    errColor=errColor+(1-errColor)*0.55;
                end
                
                switch exSettings.ChannelMode
                    case 'fNIR'
                        data2plot=curGrand.(bioM);
                    case 'ROI'
                        if(pf2_base.isnestedfield(curGrand,'ROI.HbO'))
                        data2plot=curGrand.ROI.(bioM);
                        else
                           data2plot=[]; 
                        end
                    case 'Aux'
                        data2plot=curGrand.Aux.(bioM);
                end
                
                if(~isempty(data2plot))
                    if(strcmp(errorFeature,'MaxMin'))
                      upperError=data2plot.Max(:,ch);
                      lowerError=data2plot.Min(:,ch);
                    else
                      upperError=data2plot.(plotFeature)(:,ch)+data2plot.(errorFeature)(:,ch)*errMulitply;
                      lowerError=data2plot.(plotFeature)(:,ch)-data2plot.(errorFeature)(:,ch)*errMulitply;
                    end


                    if(plotShaded)
                          errAlpha=0.15;
                          yPatch=[lowerError',fliplr(upperError')];
                          xPatch=[curGrand.time',fliplr(curGrand.time')];
                          xPatch(isnan(yPatch))=[];
                          yPatch(isnan(yPatch))=[];

                          hPatch=patch(curFigH.subH{curSy,curSx},xPatch,yPatch,-1,'facecolor',errColor,'edgecolor','none','facealpha',errAlpha);
                          if(~isempty(hPatch))
                              set(hPatch,'HitTest','off');
                              set(hPatch,'HandleVisibility','off');

                              set(hPatch.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                          end
                    end

                    if(plotGroupByBioM)
                          hGrandErr1{b}=plot(curFigH.subH{curSy,curSx},curGrand.time,upperError,'lineStyle',errStyle,'LineWidth',lineWidth,'color',errColor);
                          hGrandErr2{b}=plot(curFigH.subH{curSy,curSx},curGrand.time,lowerError,'lineStyle',errStyle,'LineWidth',lineWidth,'color',errColor);
                          set(hGrandErr1{b}.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                          set(hGrandErr2{b}.Annotation.LegendInformation,'IconDisplayStyle','off');
                          curFigH.legendHandles{curSy,curSx}.hE{b}=hGrandErr1{b};
                    else
                          hGrandErr1{g}=plot(curFigH.subH{curSy,curSx},curGrand.time,upperError,'lineStyle',errStyle,'LineWidth',lineWidth,'color',errColor);
                          hGrandErr2{g}=plot(curFigH.subH{curSy,curSx},curGrand.time,lowerError,'lineStyle',errStyle,'LineWidth',lineWidth,'color',errColor);
                          set(hGrandErr1{g}.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                          set(hGrandErr2{g}.Annotation.LegendInformation,'IconDisplayStyle','off'); 
                          curFigH.legendHandles{curSy,curSx}.hE{g}=hGrandErr1{g};
                    end



                    if(~plotGroupByBioM)
                       gAerrStrs{g}=sprintf('%s: %s',errorFeature,gbyStrs{g}); 
                       set(hGrandErr1{g},'Tag',gAerrStrs{g});
                       set(hGrandErr2{g},'Tag',gAerrStrs{g});
                    else
                       gAerrStrs{b}=sprintf('%s: %s',errorFeature,selectedBioM{b}); 
                       set(hGrandErr1{b},'Tag',gAerrStrs{b});
                       set(hGrandErr2{b},'Tag',gAerrStrs{b});
                    end
                end
            end
            
            switch exSettings.ChannelMode
                case 'fNIR'
                    chNamePart=sprintf('Opt. %s',selectedOptStr{chIdx});
                    chNamePartLong=sprintf('Optode %s',selectedOptStr{chIdx});
                case 'ROI'
                    chNamePart=selectedOptStr{chIdx};
                    chNamePartLong=sprintf('ROI: %s',selectedOptStr{chIdx});
                case 'Aux'
                    chNamePart=selectedOptStr{chIdx};
                    chNamePartLong=sprintf('Aux: %s %s',bioM,selectedOptStr{chIdx});
            end
            
            if(~plotGroupByBioM) 
                if(~strcmp(exSettings.ChannelMode,'Aux'))
                    ylbl=sprintf('\\Delta[%s] (\\muM)',bioM);
                else
                    ylbl=sprintf('%s: %s',bioM,selectedOptStr{chIdx});
                end
                if(plotCount)
                    ylbl=(sprintf('N %s',ylbl));
                end
                if(exSettings.plot_error)
                    ylbl=(sprintf('%s (%s)',ylbl,exSettings.plot_error_feature));
                end
                ylbl=(sprintf('%s %s',chNamePart,ylbl));
            elseif(plotGroupByBioM)
                if(~strcmp(exSettings.ChannelMode,'Aux'))
                    ylbl=sprintf('\\Delta[X] (\\muM)');
                else
                    ylbl=sprintf('Multiple signals');
                end
                if(plotCount)
                    ylbl=(sprintf('N %s',ylbl));
                end
                if(exSettings.plot_error)
                    ylbl=(sprintf('%s (%s)',ylbl,exSettings.plot_error_feature));
                end
                ylbl=(sprintf('%s %s',chNamePart,ylbl));
            end
            
            switch(xType)
                case 'channels'
                    title_with_space(curFigH.subH{curSy,curSx},chNamePartLong);
                case 'bioM'
                    if(~strcmp(exSettings.ChannelMode,'Aux'))
                        title_with_space(curFigH.subH{curSy,curSx},sprintf('%s: %s',bioM,selectedOptStr{chIdx}));
                    else
                        title_with_space(curFigH.subH{curSy,curSx},bioM);
                    end
                case 'groupby'
                    title_with_space(curFigH.subH{curSy,curSx},uCurInfoG{curGroupInfoIdx});
                otherwise 
            end
            
            switch(yType)
                case 'channels'
                    ylbl={chNamePartLong;ylbl};
                case 'bioM'
                    ylbl={bioM;ylbl};
                case 'groupby'
                    ylbl={uCurInfoG{curGroupInfoIdx};ylbl};
                otherwise 
            end
            ylabel_with_space(curFigH.subH{curSy,curSx},ylbl);
            
        if(exSettings.ylim_fixed)
            xlim(curFigH.subH{curSy,curSx},[exSettings.plot_start,exSettings.plot_end]);
            ylim(curFigH.subH{curSy,curSx},'auto');
            cylim=ylim(curFigH.subH{curSy,curSx});
            exSettings.ylim_fixed_min=min(exSettings.ylim_fixed_min,cylim(1));
            exSettings.ylim_fixed_max=max(exSettings.ylim_fixed_max,cylim(2));
        elseif(exSettings.ylim_manual&&~plotCount)
            ylim(curFigH.subH{curSy,curSx},[exSettings.ylim_manual_min,exSettings.ylim_manual_max]);
        else
            ylim(curFigH.subH{curSy,curSx},'auto');
        end

        curYlim=ylim(curFigH.subH{curSy,curSx});
        if(plotCount)
            exSettings.ylim_fixed_min=0;
            ylim(curFigH.subH{curSy,curSx},[0,curYlim(2)]);
        end


        end
        

    end
end

if(plotCount)
    exSettings.ylim_fixed_min=0;
end


for i=1:size(sH,1)
    for b=1:size(sH,2)
        for x=1:numSubX
            for y=1:numSubY
                xlabel_with_space(sH{i,b}.subH{y,x},'Time (s)');
                xlim(sH{i,b}.subH{y,x},[exSettings.plot_start,exSettings.plot_end]);
                
                if(exSettings.ylim_fixed)
                    ylim(sH{i,b}.subH{y,x},[exSettings.ylim_fixed_min,exSettings.ylim_fixed_max]);
                end

                if(exSettings.plot_legend_mode==3||(exSettings.plot_legend_mode==2&&(x==numSubX&&y==numSubY)))
                    if(exSettings.plot_grandaverage)
                        curHandles=curFigH.legendHandles{curSy,curSx}.hG;
                    elseif(exSettings.plot_individual)
                        curHandles=curFigH.legendHandles{curSy,curSx}.h;
                    elseif(exSettings.plot_error)
                        curHandles=curFigH.legendHandles{curSy,curSx}.hE;
                    end
                    legendGFXstrs=cell(0);
                    for h=1:length(curHandles)
                       if(~isempty(gStrs{h}))
                           %set(curHandles{h}.Annotation.LegendInformation,'IconDisplayStyle','on'); 
                           legendGFXstrs(h)=gStrs(h);
                       else

                       end
                    end
                    lgd=legend(sH{i,b}.subH{y,x},legendGFXstrs(:)','Location', 'Best');
                    lgdSty=pf2_base.plot.PlotStyle.getDefault();
                    set(lgd,'TextColor',lgdSty.LegendTextColor,'Color',lgdSty.LegendBgColor);
                end

                if(exSettings.plot_task_lines)
                    if(exSettings.use_baseline)
                        pf2_base.external.vline(sH{i,b}.subH{y,x},[exSettings.baseline_start,exSettings.baseline_end],{'--k','HandleVisibility','off'});
                    end
                    pf2_base.external.vline(sH{i,b}.subH{y,x},[exSettings.block_start,exSettings.block_end],{'--r','HandleVisibility','off'});
                end
                
                hold(sH{i,b}.subH{y,x},'off');
            end
        end
        
        addDebugAnnotation(sH{i,b}.h);
        switch(figType)
            case 'bioM'
                suptitle_with_space(sH{i,b}.h,selectedBioM{i});
            otherwise
                
        end
    end
end
end


function possibleStr=num2strOrNot(possibleStr)
if(iscell(possibleStr))
    for i=1:length(possibleStr)
       if(~ischar(possibleStr{i})&&isnumeric(possibleStr{i}))
            possibleStr{i}=num2str(possibleStr{i}); 
       end
    end

    if(iscell(possibleStr)&&all(size(possibleStr)==1))
        possibleStr=possibleStr{1};
    end
elseif(~ischar(possibleStr)&&isnumeric(possibleStr))
    possibleStr=num2str(possibleStr);
end

end

function outStr=getFormattedTrialString(fNIR)

if(~isfield(fNIR,'info'))
    outStr='Missing Info';
    return;
end

outStr='';

subStr=num2strOrNot(fNIR.info.SubjectID);
groupStr=num2strOrNot(fNIR.info.Group);
sessionStr=num2strOrNot(fNIR.info.Session);
conditionStr=num2strOrNot(fNIR.info.Condition);
trialStr=num2strOrNot(fNIR.info.Trial);
blockStr=num2strOrNot(fNIR.info.Block);

useID=true&&~isempty(subStr);
useGroup=true&&~isempty(groupStr);
useSession=true&&~isempty(sessionStr);
useCondition=true&&~isempty(conditionStr);
useTrial=true&&~isempty(trialStr);
useBlock=true&&~isempty(blockStr);

if(useID)
    outStr=sprintf('%sSubjectID:%s\n',outStr,subStr);
end
if(useGroup)
    outStr=sprintf('%sGroup:%s\n',outStr,groupStr);
end
if(useSession)
    outStr=sprintf('%sSession:%s\n',outStr,sessionStr);
end
if(useCondition)
    outStr=sprintf('%sCondition:%s\n',outStr,conditionStr);
end
if(useTrial)
    outStr=sprintf('%sTrial:%s\n',outStr,trialStr);
end
if(useBlock)
    outStr=sprintf('%sBlock:%s\n',outStr,blockStr);
end

outStr(end)='';
end



function h=xlabel_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(iscell(labelstring))
    for i=1:length(labelstring)
        labelstringTemp=labelstring{i};
        labelstringTemp(labelstringTemp=='_')=' ';
        labelstring{i}=labelstringTemp;
    end
elseif(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end

h=xlabel(figHandle,labelstring);

end

function h=ylabel_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(iscell(labelstring))
    for i=1:length(labelstring)
        labelstringTemp=labelstring{i};
        labelstringTemp(labelstringTemp=='_')=' ';
        labelstring{i}=labelstringTemp;
    end
elseif(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end
h=ylabel(figHandle,labelstring);

end

function h=title_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(iscell(labelstring))
    for i=1:length(labelstring)
        labelstringTemp=labelstring{i};
        labelstringTemp(labelstringTemp=='_')=' ';
        labelstring{i}=labelstringTemp;
    end
elseif(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end


h=title(figHandle,labelstring);

end

function h=suptitle_with_space(axHandle,labelstring)

if(nargin<2)
    labelstring=axHandle;

    if(~isempty(labelstring))
        labelstring(labelstring=='_')=' ';
    end
    h=pf2_base.external.suptitle(labelstring);
else
    if(~isempty(labelstring))
        labelstring(labelstring=='_')=' ';
    end
    h=pf2_base.external.suptitle(axHandle,labelstring);
end


end

function addDebugAnnotation(figHandle,optionalstring)
global ExFNIRS
exSettings=ExFNIRS.settings;
curTime = datetime(now,'ConvertFrom','datenum');
debugString=sprintf('%s\n%s (%s)\n%s',ExFNIRS.curMethodName,ExFNIRS.statusGroupByStr,exSettings.within_sub_avg_mode_label,curTime);
if(nargin>1)
    debugString=sprintf('%s\n%s',debugString,optionalstring);
end

debugString(debugString==('_'))='-';
th=annotation(figHandle,'textbox',[0 0 0.1 1],'String',debugString,'FitBoxToText','on');
th.FontSize = 6;
th.LineStyle='none';
th.HorizontalAlignment='left';
th.VerticalAlignment='bottom';
th.Color=pf2_base.plot.PlotStyle.getDefault().ForegroundColor;
curPos=th.Position;
end

function txt = myDataTipUpdateFcn(pointDataTip, event_obj)

    hAxes=get(pointDataTip,'Parent');
    pos = event_obj.Position;
    selectedObjectTag=event_obj.Target.Tag;
    
    if(~isempty(selectedObjectTag))
        txt={sprintf('%s\nt=%.2f, y=%.2f',selectedObjectTag,pos(1),pos(2))};
    else
        txt = {sprintf('t=%.2f, y=%.2f',pos(1),pos(2))};
    end
   %disp(['You clicked X:',num2str(pos(1)),', Y:',num2str(pos(2))]);
    
end