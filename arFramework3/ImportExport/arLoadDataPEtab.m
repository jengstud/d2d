% [Tdat, Tobs] = arLoadDataPEtab(datafilename, [m])
%
% This function can be used to process data files in the format of PEtab.
%
%   datafilename    name of file.
%
%   m               model that shall be linked to. Name or ID [length(ar.model)]
%
% In this data format, there is one single .tsv-file that contains all data
% points. This data format shall allow easier transitions between modeling
% tools.
% This load-data-function utilizes a different approach than the usual data.def file:
% Firstly, an empty data struct is created which is subsequently appended to the ar struct.
%
% See also arCreateDataStruct arAddDataStruct
%
% References
%   - https://github.com/ICB-DCM/PEtab/blob/master/doc/documentation_data_format.md

function [Tdat, Tobs] = arLoadDataPEtab(datafilename, obsfilename, m)

global ar;

if ~contains(datafilename,'.tsv')
    if ~contains(datafilename,'.')
        datafilename = [datafilename '.tsv'];
    else
        error('this file type is not supported!')
    end
end

if ~contains(obsfilename,'.tsv')
    if ~contains(obsfilename,'.')
        obsfilename = [obsfilename '.tsv'];
    else
        error('this file type is not supported!')
    end
end

if(~exist('m','var') || isempty(m))
    m = length(ar.model);
end
if(exist('m','var') && ischar(m))
    for jm=1:length(ar.model)
        if(strcmp(m, ar.model(jm).name))
            m = jm;
        end
    end
    if(ischar(m))
        error('Model %s was not found', m);
    end
end

%% Read in tsv file
Tdat = tdfread(datafilename); % all data of the model
fns = fieldnames(Tdat);
for i = 1:length(fns)
    if ischar(Tdat.(fns{i}))
        Tdat.(fns{i}) = regexprep(string(Tdat.(fns{i})),' ','');
    end
end
Tdat = struct2table(Tdat);

Tobs = tdfread(obsfilename); % all data of the model
fns = fieldnames(Tobs);
for i = 1:length(fns)
    if ischar(Tobs.(fns{i}))
        Tobs.(fns{i}) = regexprep(string(Tobs.(fns{i})),' ','');
    end
end
Tobs = struct2table(Tobs);
[uniCond,~,iCCond] = unique(Tdat.simulationConditionId);

%% Use condition specific experiments and distribute over data struct
for iCond = 1:length(uniCond)
    Sd2d = struct();
    args= {};
    pold = {}; fp = {};
    % extract important info for data struct from .tsv file
    Tsub = Tdat(iCCond == iCond,:);
    [uniObs,~,iCObs] = unique(cellstr(Tsub.observableId),'stable');
    
    [uniTimes,~,iTExp] = unique(Tsub.time);
    %    [~,ia,ic] = unique([iCobs,iTExp],'rows');
    if length(unique(iTExp(iCObs==1)))<length(iTExp(iCObs==1))
        uniTimes = Tsub.time(1:sum(iCObs==1));
        iTExp = [];
        for i=1:length(uniObs)
            iTExp = [iTExp 1:sum(iCObs==i)];
        end
        iTExp = iTExp';
    end
    uniObs = regexprep(uniObs,' ','');
    Sd2d.name = char(uniCond(iCond));
    Sd2d.tExp = uniTimes;
    Sd2d.tUnits = ar.model.tUnits;
    % observation and error functions
    Sd2d.y = uniObs';
    Sd2d.yNames = uniObs';
    for iObs = 1:length(uniObs)
        idx = strcmp(Tobs.observableId,uniObs{iObs});
        Sd2d.fy{iObs} = char(string(Tobs.observableFormula(idx)));
        tmp_fystd = char(Tobs.noiseFormula(idx));
        for jObs = 1:length(Tobs.observableId)
            tmp_fystd = arSubs(arSym(tmp_fystd),arSym(Tobs.observableId{jObs}),arSym(['(' Tobs.observableFormula{jObs} ')']));
        end
        Sd2d.fystd{iObs} = char(string(tmp_fystd));
        Sd2d.logfitting(iObs) = double(strcmp(Tobs.observableTransformation(idx),'log10'));
        % get cond specific parameter transformations
        if ~isempty(char(Tsub(1,:).observableParameters))
            poldObs = regexp(Sd2d.fy{iObs},['observableParameter\d*_' Sd2d.y{iObs}],'match');
            pnewObs = strsplit(char(Tsub(1,:).observableParameters),';');
            if ~isempty(poldObs)
                pold = [pold, poldObs];
                fp = [fp,pnewObs];
            end
        end
        if isnumeric(Tsub(1,:).noiseParameters)
            continue
        elseif ~isempty(char(Tsub(1,:).noiseParameters))
            poldNoise = regexp(Sd2d.fystd{iObs},['noiseParameter\d*_' Sd2d.y{iObs}],'match');
            pnewNoise = strsplit(char(Tsub(1,:).noiseParameters),';');
            if ~isempty(poldNoise)
                pold = [pold, poldNoise];
                fp = [fp,pnewNoise];
            end
        end
    end

    
    % experimental data
    Sd2d.yExp = nan(length(uniTimes),length(uniObs));
    Sd2d.yExpRaw = nan(length(uniTimes),length(uniObs));
    Sd2d.yExpStd = nan(length(uniTimes),length(uniObs));
    Sd2d.yExpStdRaw = nan(length(uniTimes),length(uniObs));
    for it = 1:length(uniTimes)
        for iobs = 1:length(uniObs)
%              disp([ iCond it  iobs])
            if sum(it==iTExp & iobs == iCObs)==1
                Sd2d.yExpRaw(it,iobs) = Tsub.measurement(it == iTExp & iobs == iCObs);
                Sd2d.yExp(it,iobs) = Sd2d.logfitting(iobs) * log10(Tsub.measurement(it == iTExp & iobs == iCObs)) + (1 - Sd2d.logfitting(iobs)) *Tsub.measurement(it == iTExp & iobs == iCObs);
                if isnumeric(Tsub.noiseParameters(it == iTExp & iobs == iCObs))
                    Sd2d.yExpStdRaw(it,iobs) = Tsub.noiseParameters(it == iTExp & iobs == iCObs);
                    Sd2d.yExpStd(it,iobs) =  Sd2d.logfitting(iobs) *log10(Tsub.noiseParameters(it == iTExp & iobs == iCObs)) + (1 - Sd2d.logfitting(iobs))*Tsub.noiseParameters(it == iTExp & iobs == iCObs);
                end
            elseif sum(it==iTExp & iobs == iCObs)>1
                error('Non-unique assignment for data point. Check unambiguousness of provided measurement table!')
            end
        end
    end
    Sd2d.logfitting(iobs) = 0; % We accounted for this by transforming yExp
    % prepare info for creating data struct
    fns = fieldnames(Sd2d);
    for i = 1:length(fns)
        args(end+1) = fns(i);
        args{end+1} = Sd2d.(fns{i});
    end
    args{end+1} = 'doseresponse'; args{end+1} = 0;
    if rem(length(args),2)~=0
        error('arguments args has to be provided in pairs.')
    end
    
    D = arCreateDataStruct(m,pold,fp,args{:});
    arAddDataStruct(D,m)
end

end