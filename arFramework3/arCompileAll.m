% Compile c- and mex-files for models, conditions and data sets
%
% arCompileAll(forcedCompile)
%   forcedCompile:                                   [false]
%
% See https://bitbucket.org/d2d-development/d2d-software/wiki/First%20steps 
% for description of work flow. 
%
% Copyright Andreas Raue 2013 (andreas.raue@fdm.uni-freiburg.de)

function arCompileAll(forcedCompile, debug_mode)

global ar

if(isempty(ar))
    error('please initialize by arInit')
end

if(~exist('forcedCompile','var'))
    forcedCompile = false;
end
if(~exist('debug_mode','var'))
    debug_mode = false;
end

% folders
if(~exist([cd '/Compiled'], 'dir'))
	mkdir([cd '/Compiled'])
end
if(~exist([cd '/Compiled/' ar.info.c_version_code], 'dir'))
	mkdir([cd '/Compiled/' ar.info.c_version_code])
end

% Compiled folder hook for cluster usage
fid = fopen('./Compiled/arClusterCompiledHook.m', 'W');
fprintf(fid, 'function arClusterCompiledHook\n');
fclose(fid);

warnreset = warning;
warning('off','symbolic:mupadmex:MuPADTextWarning');

% enable timedebug mode, use with debug_mode = true!
timedebug = false;

usePool = matlabpool('size')>0;

% main loop
checksum_global = addToCheckSum(ar.info.c_version_code);
c_version_code = ar.info.c_version_code;
for m=1:length(ar.model)
    fprintf('\n');
    
    % calc model
    arCalcModel(m);
    
    % extract conditions
    ar.model(m).condition = [];
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            
            % conditions checksum
            qdynparas = ismember(ar.model(m).data(d).p, ar.model(m).px) | ... %R2013a compatible
                ismember(ar.model(m).data(d).p, ar.model(m).data(d).pu); %R2013a compatible
            
            checksum_cond = addToCheckSum(ar.model(m).data(d).fu);
            checksum_cond = addToCheckSum(ar.model(m).px, checksum_cond);
            checksum_cond = addToCheckSum(ar.model(m).fv, checksum_cond);
            checksum_cond = addToCheckSum(ar.model(m).N, checksum_cond);
            checksum_cond = addToCheckSum(ar.model(m).cLink, checksum_cond);
            checksum_cond = addToCheckSum(ar.model(m).data(d).fp(qdynparas), checksum_cond);
            checkstr_cond = getCheckStr(checksum_cond);
            
            % data checksum
            checksum_data = addToCheckSum(ar.model(m).data(d).fu);
            checksum_data = addToCheckSum(ar.model(m).data(d).p, checksum_data);
            checksum_data = addToCheckSum(ar.model(m).data(d).fy, checksum_data);
            checksum_data = addToCheckSum(ar.model(m).data(d).fystd, checksum_data);
            checksum_data = addToCheckSum(ar.model(m).data(d).fp, checksum_data);
            checkstr_data = getCheckStr(checksum_data);
            
            ar.model(m).data(d).checkstr = checkstr_data;
            ar.model(m).data(d).fkt = [ar.model(m).data(d).name '_' checkstr_data];
            
            cindex = -1;
            for c=1:length(ar.model(m).condition)
                if(strcmp(checkstr_cond, ar.model(m).condition(c).checkstr))
                    cindex = c;
                end
            end
            
            % global checksum
            if(isempty(checksum_global))
                checksum_global = addToCheckSum(ar.model(m).data(d).fkt);
            else
                checksum_global = addToCheckSum(ar.model(m).data(d).fkt, checksum_global);
            end
            
            if(cindex == -1) % append new condition
                cindex = length(ar.model(m).condition) + 1;
                
                ar.model(m).condition(cindex).status = 0;
                
                ar.model(m).condition(cindex).fu = ar.model(m).data(d).fu;
                ar.model(m).condition(cindex).fp = ar.model(m).data(d).fp(qdynparas);
                ar.model(m).condition(cindex).p = ar.model(m).data(d).p(qdynparas);
                
                ar.model(m).condition(cindex).checkstr = checkstr_cond;
                ar.model(m).condition(cindex).fkt = [ar.model(m).name '_' checkstr_cond];
                
                ar.model(m).condition(cindex).dLink = d;
                
                % global checksum
                checksum_global = addToCheckSum(ar.model(m).condition(cindex).fkt, checksum_global);
                
                % link data to condition
                ar.model(m).data(d).cLink = length(ar.model(m).condition);
                
                % for multiple shooting
                if(isfield(ar.model(m).data(d), 'ms_index') && ~isempty(ar.model(m).data(d).ms_index))
                    ar.model(m).condition(cindex).ms_index = ...
                        ar.model(m).data(d).ms_index;
                    ar.model(m).condition(cindex).ms_snip_index = ...
                        ar.model(m).data(d).ms_snip_index;
                    ar.model(m).condition(cindex).ms_snip_start = ar.model(m).data(d).tLim(1);
                end
            else
                % link data to condition
                ar.model(m).condition(cindex).dLink(end+1) = d;
                ar.model(m).data(d).cLink = cindex;
                
                % for multiple shooting
                if(isfield(ar.model(m).data(d), 'ms_index') && ~isempty(ar.model(m).data(d).ms_index))
                    ar.model(m).condition(cindex).ms_index(end+1) = ...
                        ar.model(m).data(d).ms_index;
                    ar.model(m).condition(cindex).ms_snip_index(end+1) = ...
                        ar.model(m).data(d).ms_snip_index;
                    ar.model(m).condition(cindex).ms_snip_start(end+1) = ar.model(m).data(d).tLim(1);
                end
            end
        end
        
        % skip calc conditions
        doskip = nan(1,length(ar.model(m).condition));
        for c=1:length(ar.model(m).condition)
            doskip(c) = ~forcedCompile && exist(['./Compiled/' ar.info.c_version_code '/' ar.model(m).condition(c).fkt '.c'],'file');
        end
        
        % calc conditions
        config = ar.config;
        model.name = ar.model(m).name;
        model.fv = ar.model(m).fv;
        model.px0 = ar.model(m).px0;
        model.sym = ar.model(m).sym;
        model.t = ar.model(m).t;
        model.x = ar.model(m).x;
        model.u = ar.model(m).u;
        model.us = ar.model(m).us;
        model.xs = ar.model(m).xs;
        model.vs = ar.model(m).vs;
        model.N = ar.model(m).N;
        condition = ar.model(m).condition;
        newp = cell(1,length(ar.model(m).condition));
        newpold = cell(1,length(ar.model(m).condition));
        newpx0 = cell(1,length(ar.model(m).condition));
        if(usePool)
            parfor c=1:length(ar.model(m).condition)
                condition_sym = arCalcCondition(config, model, condition(c), m, c, doskip(c));
                newp{c} = condition_sym.p;
                newpold{c} = condition_sym.pold;
                newpx0{c} = condition_sym.px0;
                if(~doskip(c))
                    % header
                    fid_odeH = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.h'], 'W');
                    arWriteHFilesCondition(fid_odeH, config, condition_sym);
                    fclose(fid_odeH);
                    % body
                    fid_ode = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.c'], 'W');
                    arWriteCFilesCondition(fid_ode, config, model, condition_sym, m, c, timedebug);
                    fclose(fid_ode);
                end
            end
        else
            for c=1:length(ar.model(m).condition)
                condition_sym = arCalcCondition(config, model, condition(c), m, c, doskip(c));
                newp{c} = condition_sym.p;
                newpold{c} = condition_sym.pold;
                newpx0{c} = condition_sym.px0;
                if(~doskip(c))
                    % header
                    fid_odeH = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.h'], 'W');
                    arWriteHFilesCondition(fid_odeH, config, condition_sym);
                    fclose(fid_odeH);
                    % body
                    fid_ode = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.c'], 'W');
                    arWriteCFilesCondition(fid_ode, config, model, condition_sym, m, c, timedebug);
                    fclose(fid_ode);
                end
            end
        end
        
        % assigne conditions
        for c=1:length(ar.model(m).condition)
            ar.model(m).condition(c).p = newp{c};
            ar.model(m).condition(c).pold = newpold{c};
            ar.model(m).condition(c).px0 = newpx0{c};
        end
        
        % skip calc data
        doskip = nan(1,length(ar.model(m).data));
        for d=1:length(ar.model(m).data)
            ar.model(m).data(d).p_condition = ar.model(m).condition(ar.model(m).data(d).cLink).p;
            doskip(d) = ~forcedCompile && exist(['./Compiled/' ar.info.c_version_code '/' ar.model(m).data(d).fkt '.c'],'file');
        end
        
        % calc data
        data = ar.model(m).data;
        newp = cell(1,length(ar.model(m).data));
        newpold = cell(1,length(ar.model(m).data));
        if(usePool)
            parfor d=1:length(ar.model(m).data)
                c = data(d).cLink;
                data_sym = arCalcData(config, model, data(d), m, c, d, doskip(d));
                newp{d} = data_sym.p;
                newpold{d} = data_sym.pold;
                if(~doskip(d))
                    % header
                    fid_obsH = fopen(['./Compiled/' c_version_code '/' data(d).fkt '.h'], 'W');
                    arWriteHFilesData(fid_obsH, data_sym);
                    fclose(fid_obsH);
                    % body
                    fid_obs = fopen(['./Compiled/' c_version_code '/' data(d).fkt '.c'], 'W');
                    arWriteCFilesData(fid_obs, config, m, c, d, data_sym);
                    fclose(fid_obs);
                end
            end
        else
            for d=1:length(ar.model(m).data)
                c = data(d).cLink;
                data_sym = arCalcData(config, model, data(d), m, c, d, doskip(d));
                newp{d} = data_sym.p;
                newpold{d} = data_sym.pold;
                if(~doskip(d))
                    % header
                    fid_obsH = fopen(['./Compiled/' c_version_code '/' data(d).fkt '.h'], 'W');
                    arWriteHFilesData(fid_obsH, data_sym);
                    fclose(fid_obsH);
                    % body
                    fid_obs = fopen(['./Compiled/' c_version_code '/' data(d).fkt '.c'], 'W');
                    arWriteCFilesData(fid_obs, config, m, c, d, data_sym);
                    fclose(fid_obs);
                end
            end
        end

        % assigne data
        for d=1:length(ar.model(m).data)
            ar.model(m).data(d).p = newp{d};
            ar.model(m).data(d).pold = newpold{d};
        end
    else
        qdynparas = ismember(ar.model(m).p, ar.model(m).px) | ... %R2013a compatible
            ismember(ar.model(m).p, ar.model(m).pu); %R2013a compatible
        
        % conditions checksum
        checksum_cond = addToCheckSum(ar.model(m).fu);
        checksum_cond = addToCheckSum(ar.model(m).p(qdynparas), checksum_cond);
        checksum_cond = addToCheckSum(ar.model(m).fv, checksum_cond);
        checksum_cond = addToCheckSum(ar.model(m).N, checksum_cond);
        checksum_cond = addToCheckSum(ar.model(m).cLink, checksum_cond);
        checksum_cond = addToCheckSum(ar.model(m).fp, checksum_cond);
        
        % append condition
        cindex = 1;
        
        ar.model(m).condition(cindex).status = 0;
        ar.model(m).condition(cindex).fu = ar.model(m).fu;
        ar.model(m).condition(cindex).fp = ar.model(m).fp(qdynparas);
        ar.model(m).condition(cindex).p = ar.model(m).p(qdynparas);
        ar.model(m).condition(cindex).checkstr = getCheckStr(checksum_cond);
        ar.model(m).condition(cindex).fkt = [ar.model(m).name '_' ar.model(m).condition(cindex).checkstr];
        ar.model(m).condition(cindex).dLink = [];
        
        % global checksum
        if(isempty(checksum_global))
            checksum_global = addToCheckSum(ar.model(m).condition(cindex).fkt);
        else
            checksum_global = addToCheckSum(ar.model(m).condition(cindex).fkt, checksum_global);
        end
        
        % skip calc conditions
        doskip = nan(1,length(ar.model(m).condition));
        for c=1:length(ar.model(m).condition)
            doskip(c) = ~forcedCompile && exist(['./Compiled/' ar.info.c_version_code '/' ar.model(m).condition(c).fkt '.c'],'file');
        end
        
        % calc conditions
        config = ar.config;
        model.name = ar.model(m).name;
        model.fv = ar.model(m).fv;
        model.px0 = ar.model(m).px0;
        model.sym = ar.model(m).sym;
        model.t = ar.model(m).t;
        model.x = ar.model(m).x;
        model.u = ar.model(m).u;
        model.us = ar.model(m).us;
        model.xs = ar.model(m).xs;
        model.vs = ar.model(m).vs;
        model.N = ar.model(m).N;
        condition = ar.model(m).condition;
        newp = cell(1,length(ar.model(m).condition));
        newpold = cell(1,length(ar.model(m).condition));
        newpx0 = cell(1,length(ar.model(m).condition));
        if(usePool)
            parfor c=1:length(ar.model(m).condition)
                condition_sym = arCalcCondition(config, model, condition(c), m, c, doskip(c));
                newp{c} = condition_sym.p;
                newpold{c} = condition_sym.pold;
                newpx0{c} = condition_sym.px0;
                if(~doskip(c))
                    % header
                    fid_odeH = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.h'], 'W'); % create header file
                    arWriteHFilesCondition(fid_odeH, config, condition_sym);
                    fclose(fid_odeH);
                    % body
                    fid_ode = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.c'], 'W');
                    arWriteCFilesCondition(fid_ode, config, model, condition_sym, m, c, timedebug);
                    fclose(fid_ode);
                end
            end
        else
            for c=1:length(ar.model(m).condition)
                condition_sym = arCalcCondition(config, model, condition(c), m, c, doskip(c));
                newp{c} = condition_sym.p;
                newpold{c} = condition_sym.pold;
                newpx0{c} = condition_sym.px0;
                if(~doskip(c))
                    % header
                    fid_odeH = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.h'], 'W'); % create header file
                    arWriteHFilesCondition(fid_odeH, config, condition_sym);
                    fclose(fid_odeH);
                    % body
                    fid_ode = fopen(['./Compiled/' c_version_code '/' condition(c).fkt '.c'], 'W');
                    arWriteCFilesCondition(fid_ode, config, model, condition_sym, m, c, timedebug);
                    fclose(fid_ode);
                end
            end
        end

        % assigne conditions
        for c=1:length(ar.model(m).condition)
            ar.model(m).condition(c).p = newp{c};
            ar.model(m).condition(c).pold = newpold{c};
            ar.model(m).condition(c).px0 = newpx0{c};
        end
        
        % plot setup
        if(~isfield(ar.model(m), 'plot'))
            ar.model(m).plot(1).name = ar.model(m).name;
        else
            ar.model(m).plot(end+1).name = ar.model(m).name;
        end
        ar.model(m).plot(end).doseresponse = false;
        ar.model(m).plot(end).dLink = 0;
        ar.model(m).plot(end).ny = 0;
        ar.model(m).plot(end).condition = {};
    end
end

ar.checkstr = getCheckStr(checksum_global);
ar.fkt = ['arSimuCalcFun_' ar.checkstr];

% write arSimuCalcFunctions
writeSimuCalcFunctions(debug_mode);

% compile
arCompile(forcedCompile);

% link
arLink;

% refresh file cache
rehash

warning(warnreset);


% Calc Model
function arCalcModel(m)
global ar

fprintf('calculating model m%i, %s...\n', m, ar.model(m).name);

% make short strings
ar.model(m).xs = {};
ar.model(m).us = {};
ar.model(m).vs = {};

for j=1:length(ar.model(m).x)
    ar.model(m).xs{j} = sprintf('x[%i]',j);
end
for j=1:length(ar.model(m).u)
    ar.model(m).us{j} = sprintf('u[%i]',j);
end
for j=1:length(ar.model(m).fv)
    ar.model(m).vs{j} = sprintf('v[%i]',j);
end

% make syms
ar.model(m).sym.x = sym(ar.model(m).x);
ar.model(m).sym.xs = sym(ar.model(m).xs);
ar.model(m).sym.px0 = sym(ar.model(m).px0);
ar.model(m).sym.u = sym(ar.model(m).u);
ar.model(m).sym.us = sym(ar.model(m).us);
ar.model(m).sym.vs = sym(ar.model(m).vs);
ar.model(m).sym.fv = sym(ar.model(m).fv);

% compartment volumes
if(~isempty(ar.model(m).pc)) 
    % make syms
    ar.model(m).sym.pc = sym(ar.model(m).pc);
    ar.model(m).sym.C = sym(ones(size(ar.model(m).N)));
    
    if(~isfield(ar.model(m),'isAmountBased') || ~ar.model(m).isAmountBased)
        for j=1:size(ar.model(m).N,1) % for every species j
            qinfluxwitheducts = ar.model(m).N(j,:) > 0 & sum(ar.model(m).N < 0,1) > 0;
            eductcompartment = zeros(size(qinfluxwitheducts));
            for jj=find(qinfluxwitheducts)
				eductcompartment(jj) = unique(ar.model(m).cLink(ar.model(m).N(:,jj)<0)); %R2013a compatible
            end
            
            cfaktor = sym(ones(size(qinfluxwitheducts)));
            for jj=find(qinfluxwitheducts & eductcompartment~=ar.model(m).cLink(j))
                cfaktor(jj) = ar.model(m).sym.pc(eductcompartment(jj)) / ...
                    ar.model(m).sym.pc(ar.model(m).cLink(j));
            end
            ar.model(m).sym.C(j,:) = transpose(cfaktor);
        end
    else
        for j=1:size(ar.model(m).N,1) % for every species j
            ar.model(m).sym.C(j,:) = ar.model(m).sym.C(j,:) / ar.model(m).sym.pc(ar.model(m).cLink(j));
        end
    end
else
    ar.model(m).sym.C = sym(ones(size(ar.model(m).N)));
end

% derivatives
if(~isempty(ar.model(m).sym.fv))
    ar.model(m).sym.dfvdx = jacobian(ar.model(m).sym.fv, ar.model(m).sym.x);
    if(~isempty(ar.model(m).sym.us))
        ar.model(m).sym.dfvdu = jacobian(ar.model(m).sym.fv, ar.model(m).sym.u);
    else
        ar.model(m).sym.dfvdu = sym(ones(length(ar.model(m).sym.fv), 0));
    end
else
    ar.model(m).sym.dfvdx = sym(ones(0, length(ar.model(m).sym.x)));
    ar.model(m).sym.dfvdu = sym(ones(0, length(ar.model(m).sym.u)));
end

ar.model(m).qdvdx_nonzero = logical(ar.model(m).sym.dfvdx~=0);
ar.model(m).qdvdu_nonzero = logical(ar.model(m).sym.dfvdu~=0);

tmpsym = ar.model(m).sym.dfvdx;
tmpsym = mysubs(tmpsym, ar.model(m).sym.x, ones(size(ar.model(m).sym.x))/2);
tmpsym = mysubs(tmpsym, ar.model(m).sym.u, ones(size(ar.model(m).sym.u))/2);
tmpsym = mysubs(tmpsym, sym(ar.model(m).p), ones(size(ar.model(m).p))/2);

ar.model(m).qdvdx_negative = double(tmpsym) < 0;

tmpsym = ar.model(m).sym.dfvdu;
tmpsym = mysubs(tmpsym, ar.model(m).sym.x, ones(size(ar.model(m).sym.x))/2);
tmpsym = mysubs(tmpsym, ar.model(m).sym.u, ones(size(ar.model(m).sym.u))/2);
tmpsym = mysubs(tmpsym, sym(ar.model(m).p), ones(size(ar.model(m).p))/2);

ar.model(m).qdvdu_negative = double(tmpsym) < 0;




% Calc Condition
function condition = arCalcCondition(config, model, condition, m, c, doskip)

if(doskip)
    fprintf('calculating condition m%i c%i, %s...skipped\n', m, c, model.name);
else
    fprintf('calculating condition m%i c%i, %s...\n', m, c, model.name);
end

% hard code conditions
condition.sym.p = sym(condition.p);
condition.sym.fp = sym(condition.fp);
condition.sym.fpx0 = sym(model.px0);
condition.sym.fpx0 = mysubs(condition.sym.fpx0, condition.sym.p, condition.sym.fp);
condition.sym.fv = sym(model.fv);
condition.sym.fv = mysubs(condition.sym.fv, condition.sym.p, condition.sym.fp);
condition.sym.fu = sym(condition.fu);
condition.sym.fu = mysubs(condition.sym.fu, condition.sym.p, condition.sym.fp);
condition.sym.C = mysubs(model.sym.C, condition.sym.p, condition.sym.fp);

% predictor
condition.sym.fv = mysubs(condition.sym.fv, sym(model.t), sym('t'));
condition.sym.fu = mysubs(condition.sym.fu, sym(model.t), sym('t'));

% remaining initial conditions
qinitial = ismember(condition.p, model.px0); %R2013a compatible

varlist = cellfun(@symvar, condition.fp(qinitial), 'UniformOutput', false);
condition.px0 = union(vertcat(varlist{:}), [])'; %R2013a compatible

% remaining parameters
varlist = cellfun(@symvar, condition.fp, 'UniformOutput', false);
condition.pold = condition.p;
condition.p = setdiff(setdiff(union(vertcat(varlist{:}), [])', model.x), model.u); %R2013a compatible

if(doskip)
    condition.ps = {};
    condition.qfu_nonzero = [];
    condition.qdvdx_nonzero = [];
    condition.qdvdu_nonzero = [];
    condition.qdvdp_nonzero = [];
    condition.dvdx = {};
    condition.dvdu = {};
    condition.dvdp = {};
    condition.qdfxdx_nonzero = [];
    condition.dfxdx = {};
    condition.su = {};
    condition.sx = {};
    condition.qfsv_nonzero = [];
    condition.sv = {};
    
    return;
end

% make short strings
condition.ps = {};
for j=1:length(condition.p)
    condition.ps{j} = sprintf('p[%i]',j);
end

% make syms
condition.sym.p = sym(condition.p);
condition.sym.ps = sym(condition.ps);
condition.sym.px0s = mysubs(sym(condition.px0), ...
    condition.sym.p, condition.sym.ps);

% make syms
condition.sym.fv = mysubs(condition.sym.fv, model.sym.x, model.sym.xs);
condition.sym.fv = mysubs(condition.sym.fv, model.sym.u, model.sym.us);

condition.sym.fv = mysubs(condition.sym.fv, condition.sym.p, condition.sym.ps);
condition.sym.fu = mysubs(condition.sym.fu, condition.sym.p, condition.sym.ps);
condition.sym.fpx0 = mysubs(condition.sym.fpx0, condition.sym.p, condition.sym.ps);

% remove zero inputs
condition.qfu_nonzero = logical(condition.sym.fu ~= 0);
if(~isempty(model.sym.us))
    condition.sym.fv = mysubs(condition.sym.fv, model.sym.us(~condition.qfu_nonzero), ...
        sym(zeros(1,sum(~condition.qfu_nonzero))));
end

% derivatives
if(~isempty(condition.sym.fv))
    condition.sym.dfvdx = jacobian(condition.sym.fv, model.sym.xs);
    if(~isempty(model.sym.us))
        condition.sym.dfvdu = jacobian(condition.sym.fv, model.sym.us);
    else
        condition.sym.dfvdu = sym(ones(length(condition.sym.fv), 0));
    end
    condition.sym.dfvdp = jacobian(condition.sym.fv, condition.sym.ps);
else
    condition.sym.dfvdx = sym(ones(0, length(model.sym.xs)));
    condition.sym.dfvdu = sym(ones(0, length(model.sym.us)));
    condition.sym.dfvdp = sym(ones(0, length(condition.sym.ps)));
end

% flux signs
condition.qdvdx_nonzero = logical(condition.sym.dfvdx~=0);
condition.qdvdu_nonzero = logical(condition.sym.dfvdu~=0);
condition.qdvdp_nonzero = logical(condition.sym.dfvdp~=0);

% short terms
condition.dvdx = cell(length(model.vs), length(model.xs));
for j=1:length(model.vs)
    for i=1:length(model.xs)
        if(condition.qdvdx_nonzero(j,i))
            condition.dvdx{j,i} = sprintf('dvdx[%i]', j + (i-1)*length(model.vs));
        else
            condition.dvdx{j,i} = '0';
        end
    end
end
condition.sym.dvdx = sym(condition.dvdx);

condition.dvdu = cell(length(model.vs), length(model.us));
for j=1:length(model.vs)
    for i=1:length(model.us)
        if(condition.qdvdu_nonzero(j,i))
            condition.dvdu{j,i} = sprintf('dvdu[%i]', j + (i-1)*length(model.vs));
        else
            condition.dvdu{j,i} = '0';
        end
    end
end
condition.sym.dvdu = sym(condition.dvdu);

condition.dvdp = cell(length(model.vs), length(condition.ps));
for j=1:length(model.vs)
    for i=1:length(condition.ps)
        if(condition.qdvdp_nonzero(j,i))
            condition.dvdp{j,i} = sprintf('dvdp[%i]', j + (i-1)*length(model.vs));
        else
            condition.dvdp{j,i} = '0';
        end
    end
end
condition.sym.dvdp = sym(condition.dvdp);

% make equations
condition.sym.C = mysubs(condition.sym.C, condition.sym.p, condition.sym.ps);
condition.sym.fx = (model.N .* condition.sym.C) * transpose(model.sym.vs);

% Jacobian dfxdx
if(config.useJacobian)
    condition.sym.dfxdx = (model.N .* condition.sym.C) * condition.sym.dvdx;
    condition.qdfxdx_nonzero = logical(condition.sym.dfxdx~=0);
    for j=1:length(model.xs)
        for i=1:length(model.xs)
            if(condition.qdfxdx_nonzero(j,i))
                condition.dfxdx{j,i} = sprintf('dfxdx[%i]', j + (i-1)*length(model.xs));
            else
                condition.dfxdx{j,i} = '0';
            end
        end
    end
end

% sx sensitivities
if(config.useSensis)
	% su
    condition.su = cell(length(model.us), 1);
    for j=1:length(model.us)
        if(condition.qfu_nonzero(j))
            condition.su{j} = sprintf('su[%i]', j);
        else
            condition.su{j} = '0';
        end
    end
    condition.sym.su = sym(condition.su);
    
    % input derivatives 
    if(~isempty(condition.sym.ps))
        if(~isempty(condition.sym.fu))
            condition.sym.dfudp = ...
                jacobian(condition.sym.fu, condition.sym.ps);
        else
            condition.sym.dfudp = sym(ones(0,length(condition.sym.ps)));
        end
        % derivatives of step1 (DISABLED)
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'step1('))
                condition.sym.dfudp(j,:) = 0;
            end
        end
        
        % derivatives of step2 (DISABLED)
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'step2('))
                condition.sym.dfudp(j,:) = 0;
            end
        end
        
        % derivatives of spline3
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline3('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline3)('))
                        ustr = strrep(ustr, 'D([3], spline3)(', 'Dspline3(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline3)('))
                        ustr = strrep(ustr, 'D([5], spline3)(', 'Dspline3(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline3)('))
                        ustr = strrep(ustr, 'D([7], spline3)(', 'Dspline3(');
                        ustr = strrep(ustr, ')', ', 3)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline_pos3
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline_pos3('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline_pos3)('))
                        ustr = strrep(ustr, 'D([3], spline_pos3)(', 'Dspline_pos3(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline_pos3)('))
                        ustr = strrep(ustr, 'D([5], spline_pos3)(', 'Dspline_pos3(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline_pos3)('))
                        ustr = strrep(ustr, 'D([7], spline_pos3)(', 'Dspline_pos3(');
                        ustr = strrep(ustr, ')', ', 3)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline4
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline4('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline4)('))
                        ustr = strrep(ustr, 'D([3], spline4)(', 'Dspline4(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline4)('))
                        ustr = strrep(ustr, 'D([5], spline4)(', 'Dspline4(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline4)('))
                        ustr = strrep(ustr, 'D([7], spline4)(', 'Dspline4(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline4)('))
                        ustr = strrep(ustr, 'D([9], spline4)(', 'Dspline4(');
                        ustr = strrep(ustr, ')', ', 4)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline_pos4
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline_pos4('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline_pos4)('))
                        ustr = strrep(ustr, 'D([3], spline_pos4)(', 'Dspline_pos4(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline_pos4)('))
                        ustr = strrep(ustr, 'D([5], spline_pos4)(', 'Dspline_pos4(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline_pos4)('))
                        ustr = strrep(ustr, 'D([7], spline_pos4)(', 'Dspline_pos4(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline_pos4)('))
                        ustr = strrep(ustr, 'D([9], spline_pos4)(', 'Dspline_pos4(');
                        ustr = strrep(ustr, ')', ', 4)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline5
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline5('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline5)('))
                        ustr = strrep(ustr, 'D([3], spline5)(', 'Dspline5(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline5)('))
                        ustr = strrep(ustr, 'D([5], spline5)(', 'Dspline5(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline5)('))
                        ustr = strrep(ustr, 'D([7], spline5)(', 'Dspline5(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline5)('))
                        ustr = strrep(ustr, 'D([9], spline5)(', 'Dspline5(');
                        ustr = strrep(ustr, ')', ', 4)');
                    elseif(strfind(ustr, 'D([11], spline5)('))
                        ustr = strrep(ustr, 'D([11], spline5)(', 'Dspline5(');
                        ustr = strrep(ustr, ')', ', 5)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline_pos5
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline_pos5('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline_pos5)('))
                        ustr = strrep(ustr, 'D([3], spline_pos5)(', 'Dspline_pos5(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline_pos5)('))
                        ustr = strrep(ustr, 'D([5], spline_pos5)(', 'Dspline_pos5(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline_pos5)('))
                        ustr = strrep(ustr, 'D([7], spline_pos5)(', 'Dspline_pos5(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline_pos5)('))
                        ustr = strrep(ustr, 'D([9], spline_pos5)(', 'Dspline_pos5(');
                        ustr = strrep(ustr, ')', ', 4)');
                    elseif(strfind(ustr, 'D([11], spline_pos5)('))
                        ustr = strrep(ustr, 'D([11], spline_pos5)(', 'Dspline_pos5(');
                        ustr = strrep(ustr, ')', ', 5)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
          % derivatives of spline10
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline10('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline10)('))
                        ustr = strrep(ustr, 'D([3], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline10)('))
                        ustr = strrep(ustr, 'D([5], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline10)('))
                        ustr = strrep(ustr, 'D([7], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline10)('))
                        ustr = strrep(ustr, 'D([9], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 4)');
                    elseif(strfind(ustr, 'D([11], spline10)('))
                        ustr = strrep(ustr, 'D([11], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 5)');
                    elseif(strfind(ustr, 'D([13], spline10)('))
                        ustr = strrep(ustr, 'D([13], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 6)');
                    elseif(strfind(ustr, 'D([15], spline10)('))
                        ustr = strrep(ustr, 'D([15], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 7)');
                    elseif(strfind(ustr, 'D([17], spline10)('))
                        ustr = strrep(ustr, 'D([17], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 8)');
                    elseif(strfind(ustr, 'D([19], spline10)('))
                        ustr = strrep(ustr, 'D([19], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 9)');
                    elseif(strfind(ustr, 'D([21], spline10)('))
                        ustr = strrep(ustr, 'D([21], spline10)(', 'Dspline10(');
                        ustr = strrep(ustr, ')', ', 10)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end
        
        % derivatives of spline_pos10
        for j=1:length(model.u)
            if(strfind(condition.fu{j}, 'spline_pos10('))
                for j2=1:length(condition.sym.dfudp(j,:))
                    ustr = char(condition.sym.dfudp(j,j2));
                    if(strfind(ustr, 'D([3], spline_pos10)('))
                        ustr = strrep(ustr, 'D([3], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 1)');
                    elseif(strfind(ustr, 'D([5], spline_pos10)('))
                        ustr = strrep(ustr, 'D([5], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 2)');
                    elseif(strfind(ustr, 'D([7], spline_pos10)('))
                        ustr = strrep(ustr, 'D([7], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 3)');
                    elseif(strfind(ustr, 'D([9], spline_pos10)('))
                        ustr = strrep(ustr, 'D([9], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 4)');
                    elseif(strfind(ustr, 'D([11], spline_pos10)('))
                        ustr = strrep(ustr, 'D([11], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 5)');
                    elseif(strfind(ustr, 'D([13], spline_pos10)('))
                        ustr = strrep(ustr, 'D([13], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 6)');
                    elseif(strfind(ustr, 'D([15], spline_pos10)('))
                        ustr = strrep(ustr, 'D([15], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 7)');
                    elseif(strfind(ustr, 'D([17], spline_pos10)('))
                        ustr = strrep(ustr, 'D([17], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 8)');
                    elseif(strfind(ustr, 'D([19], spline_pos10)('))
                        ustr = strrep(ustr, 'D([19], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 9)');
                    elseif(strfind(ustr, 'D([21], spline_pos10)('))
                        ustr = strrep(ustr, 'D([21], spline_pos10)(', 'Dspline_pos10(');
                        ustr = strrep(ustr, ')', ', 10)');
                    end
                    condition.sym.dfudp(j,j2) = sym(ustr);
                end
            end
        end 
    end
    
	% sx
    condition.sx = cell(length(model.xs), 1);
    for j=1:length(model.xs)
        condition.sx{j} = sprintf('sx[%i]', j);
    end
	condition.sym.sx = sym(condition.sx);
    
    condition.sym.fsv1 = condition.sym.dvdx * condition.sym.sx + ...
        condition.sym.dvdu * condition.sym.su;
    % fsv2 = condition.sym.dvdp;
    
	% sv
    condition.sv = cell(length(model.vs), 1);
    for j=1:length(model.vs)
        condition.sv{j} = sprintf('sv[%i]', j);
    end
    condition.sym.sv = sym(condition.sv);
    
    if(config.useSensiRHS)
        condition.sym.fsx = (model.N .* condition.sym.C) * condition.sym.sv;
    end
    
    % sx initials
    if(~isempty(condition.sym.fpx0))
        condition.sym.fsx0 = jacobian(condition.sym.fpx0, condition.sym.ps);
    else
        condition.sym.fsx0 = sym(ones(0, length(condition.sym.ps)));
    end
    
    % steady state sensitivities
    condition.sym.dfxdp = (model.N .* condition.sym.C) * (condition.sym.dvdp + ...
        condition.sym.dvdx*condition.sym.fsx0 + ...
        condition.sym.dvdu * condition.sym.dfudp);
end




% Calc Data
function data = arCalcData(config, model, data, m, c, d, doskip)

if(doskip)
    fprintf('calculating data m%i d%i -> c%i, %s...skipped\n', m, d, c, data.name);
else
    fprintf('calculating data m%i d%i -> c%i, %s...\n', m, d, c, data.name);
end

% hard code conditions
data.sym.p = sym(data.p);
data.sym.fp = sym(data.fp);
data.sym.fy = sym(data.fy);
data.sym.fy = mysubs(data.sym.fy, data.sym.p, data.sym.fp);
data.sym.fystd = sym(data.fystd);
data.sym.fystd = mysubs(data.sym.fystd, data.sym.p, data.sym.fp);

data.sym.fu = sym(data.fu);
data.sym.fu = mysubs(data.sym.fu, data.sym.p, data.sym.fp);
data.qfu_nonzero = logical(data.sym.fu ~= 0);

% predictor
data.sym.fu = mysubs(data.sym.fu, sym(model.t), sym('t'));
data.sym.fy = mysubs(data.sym.fy, sym(model.t), sym('t'));
data.sym.fystd = mysubs(data.sym.fystd, sym(model.t), sym('t'));

% remaining parameters
varlist = cellfun(@symvar, data.fp, 'UniformOutput', false);
data.pold = data.p;
data.p = setdiff(setdiff(union(vertcat(varlist{:}), [])', model.x), model.u); %R2013a compatible

if(doskip)
    data.ps = {};
    data.ys = [];
    data.qu_measured = [];
    data.qx_measured = [];
    data.dfydxnon0 = {};
    data.sx = {};
    data.sy = {};
    
    return;
end

% make short strings
for j=1:length(data.p)
    data.ps{j} = sprintf('p[%i]',j);
end
data.ys = {};
for j=1:length(data.y)
    data.ys{j} = sprintf('y[%i]',j);
end

% make syms
data.sym.p = sym(data.p);
data.sym.ps = sym(data.ps);
data.sym.y = sym(data.y);
data.sym.ys = sym(data.ys);

% substitute
data.sym.fy = mysubs(data.sym.fy, ...
    model.sym.x, model.sym.xs);
data.sym.fy = mysubs(data.sym.fy, ...
    model.sym.u, model.sym.us);
data.sym.fy = mysubs(data.sym.fy, ...
    data.sym.p, data.sym.ps);

data.sym.fystd = mysubs(data.sym.fystd, ...
    model.sym.x, model.sym.xs);
data.sym.fystd = mysubs(data.sym.fystd, ...
    model.sym.u, model.sym.us);
data.sym.fystd = mysubs(data.sym.fystd, ...
    data.sym.y, data.sym.ys);
data.sym.fystd = mysubs(data.sym.fystd, ...
    data.sym.p, data.sym.ps);

% derivatives fy
if(~isempty(data.sym.fy))
    if(~isempty(model.sym.us))
        data.sym.dfydu = jacobian(data.sym.fy, model.sym.us);
    else
        data.sym.dfydu = sym(ones(length(data.y), 0));
    end
    if(~isempty(model.x))
        data.sym.dfydx = jacobian(data.sym.fy, model.sym.xs);
    else
        data.sym.dfydx = [];
    end
	data.sym.dfydp = jacobian(data.sym.fy, data.sym.ps);
else
	data.sym.dfydu = [];
	data.sym.dfydx = [];
	data.sym.dfydp = [];
end

% what is measured ?
data.qu_measured = sum(logical(data.sym.dfydu~=0),1)>0;
data.qx_measured = sum(logical(data.sym.dfydx~=0),1)>0;

% derivatives fystd
if(~isempty(data.sym.fystd))
    if(~isempty(model.sym.us))
        data.sym.dfystddu = jacobian(data.sym.fystd, model.sym.us);
    else
        data.sym.dfystddu = sym(ones(length(data.y), 0));
    end
    if(~isempty(model.x))
        data.sym.dfystddx = jacobian(data.sym.fystd, model.sym.xs);
    else
        data.sym.dfystddx = [];
    end
    data.sym.dfystddp = jacobian(data.sym.fystd, data.sym.ps);
    data.sym.dfystddy = jacobian(data.sym.fystd, data.sym.ys);
else
	data.sym.dfystddp = [];
	data.sym.dfystddy = [];
    data.sym.dfystddx = [];
end

% observed directly and exclusively
data.dfydxnon0 = logical(data.sym.dfydx ~= 0);

if(config.useSensis)
    % sx sensitivities
    data.sx = {};
    for j=1:length(model.xs)
        for i=1:length(data.p_condition)
            data.sx{j,i} = sprintf('sx[%i]', j + (i-1)*length(model.xs));
        end
    end
    data.sym.sx = sym(data.sx);
    
    % su
    data.su = cell(length(model.us), length(data.p_condition));
    for j=1:length(model.us)
        for i=1:length(data.p_condition)
            if(data.qfu_nonzero(j))
                data.su{j,i} = sprintf('su[%i]', j + (i-1)*length(model.us));
            else
                data.su{j,i} = '0';
            end
        end
    end
    data.sym.su = sym(data.su);
    
    % sy sensitivities
    data.sy = {};
    for j=1:length(data.sym.fy)
        for i=1:length(data.sym.ps)
            data.sy{j,i} = sprintf('sy[%i]', j + (i-1)*length(data.sym.fy));
        end
    end
	data.sym.sy = sym(data.sy);
    
    % parameters that appear in conditions
    if(~isempty(data.p_condition))
        qdynpara = ismember(data.p, data.p_condition); %R2013a compatible
    else
        qdynpara = false(size(data.p));
    end
    
    % calculate sy
    if(~isempty(data.sym.sy))
        data.sym.fsy = data.sym.dfydp;
        
        if(~isempty(data.p_condition))
            tmpfsx = data.sym.dfydx * ...
                data.sym.sx;
            tmpfsu = data.sym.dfydu * ...
                data.sym.su;
            if(~isempty(model.x))
                data.sym.fsy(:,qdynpara) = data.sym.fsy(:,qdynpara) + tmpfsx + tmpfsu;
            else
                data.sym.fsy(:,qdynpara) = data.sym.fsy(:,qdynpara) + tmpfsu;
            end
        end
    else
        data.sym.fsy = [];
    end
    
    % calculate systd
    if(~isempty(data.sym.sy))
        data.sym.fsystd = data.sym.dfystddp + ...
            data.sym.dfystddy * data.sym.sy;
                
        if(~isempty(data.p_condition))
            tmpfsx = data.sym.dfystddx * ...
                data.sym.sx;
            tmpfsu = data.sym.dfystddu * ...
                data.sym.su;
            if(~isempty(model.x))
                data.sym.fsystd(:,qdynpara) = data.sym.fsystd(:,qdynpara) + tmpfsx + tmpfsu;
            else
                data.sym.fsystd(:,qdynpara) = data.sym.fsystd(:,qdynpara) + tmpfsu;
            end
        end
    else
        data.sym.fsystd = [];
    end
end


% better subs
function out = mysubs(in, old, new)
if(~isnumeric(in) && ~isempty(old) && ~isempty(findsym(in)))
    matVer = ver('MATLAB');
    if(str2double(matVer.Version)>=8.1)
        out = subs(in, old(:), new(:));
    else
        out = subs(in, old(:), new(:), 0);
    end
else
    out = in;
end

function checksum = addToCheckSum(str, checksum)
algs = {'MD2','MD5','SHA-1','SHA-256','SHA-384','SHA-512'};
if(nargin<2)
    checksum = java.security.MessageDigest.getInstance(algs{2});
end
if(iscell(str))
    for j=1:length(str)
        checksum = addToCheckSum(str{j}, checksum);
    end
else
    if(~isempty(str))
        checksum.update(uint8(str(:)));
    end
end

function checkstr = getCheckStr(checksum)
h = typecast(checksum.digest,'uint8');
checkstr = dec2hex(h)';
checkstr = checkstr(:)';

clear checksum

% write ODE headers
function arWriteHFilesCondition(fid, config, condition)

fprintf(fid, '#ifndef _MY_%s\n', condition.fkt);
fprintf(fid, '#define _MY_%s\n\n', condition.fkt);

fprintf(fid, '#include <cvodes/cvodes.h>\n'); 
fprintf(fid, '#include <cvodes/cvodes_dense.h>\n');
fprintf(fid, '#include <nvector/nvector_serial.h>\n');
fprintf(fid, '#include <sundials/sundials_types.h>\n'); 
fprintf(fid, '#include <sundials/sundials_math.h>\n');  
fprintf(fid, '#include <udata.h>\n');
fprintf(fid, '#include <math.h>\n');
fprintf(fid, '#include <mex.h>\n');
fprintf(fid, '#include <arInputFunctionsC.h>\n');
fprintf(fid,'\n\n\n');

fprintf(fid, ' void fu_%s(void *user_data, double t);\n', condition.fkt);
fprintf(fid, ' void fsu_%s(void *user_data, double t);\n', condition.fkt);
fprintf(fid, ' void fv_%s(realtype t, N_Vector x, void *user_data);\n', condition.fkt);
fprintf(fid, ' void dvdx_%s(realtype t, N_Vector x, void *user_data);\n', condition.fkt);
fprintf(fid, ' void dvdu_%s(realtype t, N_Vector x, void *user_data);\n', condition.fkt);
fprintf(fid, ' void dvdp_%s(realtype t, N_Vector x, void *user_data);\n', condition.fkt);
fprintf(fid, ' int fx_%s(realtype t, N_Vector x, N_Vector xdot, void *user_data);\n', condition.fkt);
fprintf(fid, ' void fxdouble_%s(realtype t, N_Vector x, double *xdot_tmp, void *user_data);\n', condition.fkt);
fprintf(fid, ' void fx0_%s(N_Vector x0, void *user_data);\n', condition.fkt);
% fprintf(fid, ' int dfxdx_%s(int N, realtype t, N_Vector x,', condition.fkt); % sundials 2.4.0
fprintf(fid, ' int dfxdx_%s(long int N, realtype t, N_Vector x,', condition.fkt); % sundials 2.5.0
fprintf(fid, 'N_Vector fx, DlsMat J, void *user_data,');
fprintf(fid, 'N_Vector tmp1, N_Vector tmp2, N_Vector tmp3);\n');
if(config.useSensiRHS)
    fprintf(fid, ' int fsx_%s(int Ns, realtype t, N_Vector x, N_Vector xdot,', condition.fkt);
    fprintf(fid, 'int ip, N_Vector sx, N_Vector sxdot, void *user_data,');
    fprintf(fid, 'N_Vector tmp1, N_Vector tmp2);\n');
end
fprintf(fid, ' void fsx0_%s(int ip, N_Vector sx0, void *user_data);\n', condition.fkt);
fprintf(fid, ' void dfxdp_%s(realtype t, N_Vector x, double *dfxdp, void *user_data);\n\n', condition.fkt);
fprintf(fid, '#endif /* _MY_%s */\n', condition.fkt);

fprintf(fid,'\n\n\n');


% Write Condition
function arWriteCFilesCondition(fid, config, model, condition, m, c, timedebug)

fprintf(' -> writing condition m%i c%i, %s...\n', m, c, model.name);

fprintf(fid, '#include "%s.h"\n',  condition.fkt);
fprintf(fid, '#include <cvodes/cvodes.h>\n');    
fprintf(fid, '#include <cvodes/cvodes_dense.h>\n');
fprintf(fid, '#include <nvector/nvector_serial.h>\n');
fprintf(fid, '#include <sundials/sundials_types.h>\n'); 
fprintf(fid, '#include <sundials/sundials_math.h>\n');  
fprintf(fid, '#include <udata.h>\n');
fprintf(fid, '#include <math.h>\n');
fprintf(fid, '#include <mex.h>\n');
fprintf(fid, '#include <arInputFunctionsC.h>\n');
fprintf(fid,'\n\n\n');

% write fu
fprintf(fid, ' void fu_%s(void *user_data, double t)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t fu\\n", t);\n'); 
end;
if(~isempty(model.us))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    writeCcode(fid, condition, 'fu');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write fsu
fprintf(fid, ' void fsu_%s(void *user_data, double t)\n{\n', condition.fkt);
if(config.useSensis)
    if(sum(logical(condition.sym.dfudp(:)~=0))>0)
        fprintf(fid, '  UserData data = (UserData) user_data;\n');
        fprintf(fid, '  double *p = data->p;\n');
    
        writeCcode(fid, condition, 'fsu');
    end
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write v
fprintf(fid, ' void fv_%s(realtype t, N_Vector x, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t fv\\n", t);\n');
end
if(~isempty(model.xs))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
    writeCcode(fid, condition, 'fv');
end

fprintf(fid, '\n  return;\n}\n\n\n');

% write dvdx
fprintf(fid, ' void dvdx_%s(realtype t, N_Vector x, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t dvdx\\n", t);\n');
end
if(~isempty(model.xs))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
    writeCcode(fid, condition, 'dvdx');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write dvdu
fprintf(fid, ' void dvdu_%s(realtype t, N_Vector x, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t dvdu\\n", t);\n');
end
if(~isempty(model.us) && ~isempty(model.xs))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
    writeCcode(fid, condition, 'dvdu');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write dvdp
fprintf(fid, ' void dvdp_%s(realtype t, N_Vector x, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
	fprintf(fid, '  printf("%%g \\t dvdp\\n", t);\n');
end
if(~isempty(model.xs))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
    if(~isempty(condition.sym.dfvdp))
        writeCcode(fid, condition, 'dvdp');
    end
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write fx
fprintf(fid, ' int fx_%s(realtype t, N_Vector x, N_Vector xdot, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t fx\\n", t);\n');
end
if(~isempty(model.xs))
    fprintf(fid, '  int is;\n');
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *qpositivex = data->qpositivex;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *v = data->v;\n');
    fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
    fprintf(fid, '  double *xdot_tmp = N_VGetArrayPointer(xdot);\n');
    fprintf(fid, '  fu_%s(data, t);\n', condition.fkt);
    fprintf(fid, '  fv_%s(t, x, data);\n', condition.fkt);
    writeCcode(fid, condition, 'fx');
    fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(model.xs));
    fprintf(fid, '    if(mxIsNaN(xdot_tmp[is])) xdot_tmp[is] = 0.0;\n');
    fprintf(fid, '    if(qpositivex[is]>0.5 && x_tmp[is]<0.0 && xdot_tmp[is]<0.0) xdot_tmp[is] = -xdot_tmp[is];\n');
    fprintf(fid, '  }\n');
end

fprintf(fid, '\n  return(0);\n}\n\n\n');

% write fxdouble
fprintf(fid, ' void fxdouble_%s(realtype t, N_Vector x, double *xdot_tmp, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
    fprintf(fid, '  printf("%%g \\t fxdouble\\n", t);\n');
end
if(~isempty(model.xs))
    fprintf(fid, '  int is;\n');
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *v = data->v;\n');
    fprintf(fid, '  fu_%s(data, t);\n', condition.fkt);
    fprintf(fid, '  fv_%s(t, x, data);\n', condition.fkt);
    writeCcode(fid, condition, 'fx');
    fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(model.xs));
    fprintf(fid, '    if(mxIsNaN(xdot_tmp[is])) xdot_tmp[is] = 0.0;\n');
    fprintf(fid, '  }\n');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write fx0
fprintf(fid, ' void fx0_%s(N_Vector x0, void *user_data)\n{\n', condition.fkt);
if(~isempty(model.xs))
    fprintf(fid, '  UserData data = (UserData) user_data;\n');
    fprintf(fid, '  double *p = data->p;\n');
    fprintf(fid, '  double *u = data->u;\n');
    fprintf(fid, '  double *x0_tmp = N_VGetArrayPointer(x0);\n');
    writeCcode(fid, condition, 'fx0');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write dfxdx
% fprintf(fid, ' int dfxdx_%s(int N, realtype t, N_Vector x, \n', condition.fkt); % sundials 2.4.0
fprintf(fid, ' int dfxdx_%s(long int N, realtype t, N_Vector x, \n', condition.fkt); % sundials 2.5.0
fprintf(fid, '  \tN_Vector fx, DlsMat J, void *user_data, \n');
fprintf(fid, '  \tN_Vector tmp1, N_Vector tmp2, N_Vector tmp3)\n{\n');
if(timedebug)
    fprintf(fid, '  printf("%%g \\t dfxdx\\n", t);\n');
end

if(~isempty(model.xs))
    if(config.useJacobian)
        fprintf(fid, '  int is;\n');
        fprintf(fid, '  UserData data = (UserData) user_data;\n');
        fprintf(fid, '  double *p = data->p;\n');
        fprintf(fid, '  double *u = data->u;\n');
        fprintf(fid, '  double *dvdx = data->dvdx;\n');
        % fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
        fprintf(fid, '  dvdx_%s(t, x, data);\n', condition.fkt);
        fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(model.xs)^2);
        fprintf(fid, '    J->data[is] = 0.0;\n');
        fprintf(fid, '  }\n');
        writeCcode(fid, condition, 'dfxdx');
        fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(model.xs)^2);
        fprintf(fid, '    if(mxIsNaN(J->data[is])) J->data[is] = 0.0;\n');
        fprintf(fid, '  }\n');
    end
end
fprintf(fid, '\n  return(0);\n}\n\n\n');

% write fsv & fsx
if(config.useSensiRHS)
    fprintf(fid, ' int fsx_%s(int Ns, realtype t, N_Vector x, N_Vector xdot, \n', condition.fkt);
    fprintf(fid, '  \tint ip, N_Vector sx, N_Vector sxdot, void *user_data, \n');
    fprintf(fid, '  \tN_Vector tmp1, N_Vector tmp2)\n{\n');
    
    if(~isempty(model.xs))
        if(config.useSensis)
            fprintf(fid, '  int is;\n');
            fprintf(fid, '  UserData data = (UserData) user_data;\n');
            fprintf(fid, '  double *p = data->p;\n');
            fprintf(fid, '  double *u = data->u;\n');
            fprintf(fid, '  double *sv = data->sv;\n');
            fprintf(fid, '  double *dvdx = data->dvdx;\n');
            fprintf(fid, '  double *dvdu = data->dvdu;\n');
            fprintf(fid, '  double *dvdp = data->dvdp;\n');
            fprintf(fid, '  double *su = data->su;\n');
            % 	fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
            fprintf(fid, '  double *sx_tmp = N_VGetArrayPointer(sx);\n');
            fprintf(fid, '  double *sxdot_tmp = N_VGetArrayPointer(sxdot);\n');
            
            if(timedebug)
                fprintf(fid, '  printf("%%g \\t fsx%%i\\n", t, ip);\n');
            end
            fprintf(fid, '  fsu_%s(data, t);\n', condition.fkt);
            fprintf(fid, '  dvdx_%s(t, x, data);\n', condition.fkt);
            fprintf(fid, '  dvdu_%s(t, x, data);\n', condition.fkt);
            fprintf(fid, '  dvdp_%s(t, x, data);\n', condition.fkt);
            
            fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(condition.sv));
            fprintf(fid, '    sv[is] = 0.0;\n');
            fprintf(fid, '  }\n');
            
            writeCcode(fid, condition, 'fsv1');
            fprintf(fid, '  switch (ip) {\n');
            for j2=1:size(condition.sym.dvdp,2)
                fprintf(fid, '    case %i: {\n', j2-1);
                writeCcode(fid, condition, 'fsv2', j2);
                fprintf(fid, '    } break;\n');
            end
            fprintf(fid, '  }\n');
            writeCcode(fid, condition, 'fsx');
            
            fprintf(fid, '  for (is=0; is<%i; is++) {\n', length(model.xs));
            fprintf(fid, '    if(mxIsNaN(sxdot_tmp[is])) sxdot_tmp[is] = 0.0;\n');
            fprintf(fid, '  }\n');
        end
    end
    fprintf(fid, '\n  return(0);\n}\n\n\n');
end


% write fsx0
fprintf(fid, ' void fsx0_%s(int ip, N_Vector sx0, void *user_data)\n{\n', condition.fkt);
if(~isempty(model.xs))
    if(config.useSensis)
        fprintf(fid, '  UserData data = (UserData) user_data;\n');
        fprintf(fid, '  double *p = data->p;\n');
        fprintf(fid, '  double *u = data->u;\n');
        fprintf(fid, '  double *sx0_tmp = N_VGetArrayPointer(sx0);\n');
        
        % Equations
        fprintf(fid, '  switch (ip) {\n');
        for j2=1:size(condition.sym.fsx0,2)
            if(sum(logical(condition.sym.fsx0(:,j2)~=0))>0)
                fprintf(fid, '    case %i: {\n', j2-1);
                writeCcode(fid, condition, 'fsx0', j2);
                fprintf(fid, '    } break;\n');
            end
        end
        fprintf(fid, '  }\n');
    end
end
fprintf(fid, '\n  return;\n}\n\n\n');


% write dfxdp
fprintf(fid, ' void dfxdp_%s(realtype t, N_Vector x, double *dfxdp, void *user_data)\n{\n', condition.fkt);
if(timedebug) 
	fprintf(fid, '  printf("%%g \\t dfxdp\\n", t);\n');
end
if(~isempty(model.xs))
    if(config.useSensis)
        if(~isempty(condition.sym.dfxdp))
            fprintf(fid, '  int is;\n');
            fprintf(fid, '  UserData data = (UserData) user_data;\n');
            fprintf(fid, '  double *p = data->p;\n');
            fprintf(fid, '  double *u = data->u;\n');
            fprintf(fid, '  double *dvdp = data->dvdp;\n');
            fprintf(fid, '  double *dvdx = data->dvdx;\n');
            fprintf(fid, '  double *dvdu = data->dvdu;\n');
            fprintf(fid, '  double *x_tmp = N_VGetArrayPointer(x);\n');
            writeCcode(fid, condition, 'dfxdp');
            fprintf(fid, '  for (is=0; is<%i; is++) {\n', numel(condition.sym.dfxdp));
            fprintf(fid, '    if(mxIsNaN(dfxdp[is])) dfxdp[is] = 0.0;\n');
            fprintf(fid, '  }\n');
        end
    end
end
fprintf(fid, '\n  return;\n}\n\n\n');


% write data headers
function arWriteHFilesData(fid, data)

fprintf(fid, '#ifndef _MY_%s\n', data.fkt);
fprintf(fid, '#define _MY_%s\n\n', data.fkt);

fprintf(fid, '#include <cvodes/cvodes.h>\n'); 
fprintf(fid, '#include <cvodes/cvodes_dense.h>\n');
fprintf(fid, '#include <nvector/nvector_serial.h>\n');
fprintf(fid, '#include <sundials/sundials_types.h>\n'); 
fprintf(fid, '#include <sundials/sundials_math.h>\n');  
fprintf(fid, '#include <udata.h>\n');
fprintf(fid, '#include <math.h>\n');
fprintf(fid, '#include <mex.h>\n');
fprintf(fid, '#include <arInputFunctionsC.h>\n');
fprintf(fid,'\n\n\n');

fprintf(fid, ' void fy_%s(double t, int nt, int it, int ntlink, int itlink, int ny, int nx, int iruns, double *y, double *p, double *u, double *x);\n', data.fkt);
fprintf(fid, ' void fystd_%s(double t, int nt, int it, int ntlink, int itlink, double *ystd, double *y, double *p, double *u, double *x);\n', data.fkt);
fprintf(fid, ' void fsy_%s(double t, int nt, int it, int ntlink, int itlink, double *sy, double *p, double *u, double *x, double *su, double *sx);\n', data.fkt);
fprintf(fid, ' void fsystd_%s(double t, int nt, int it, int ntlink, int itlink, double *systd, double *p, double *y, double *u, double *x, double *sy, double *su, double *sx);\n\n', data.fkt);

fprintf(fid, '#endif /* _MY_%s */\n', data.fkt);
fprintf(fid,'\n\n\n');


% Write Data
function arWriteCFilesData(fid, config, m, c, d, data)

fprintf(' -> writing data m%i d%i -> c%i, %s...\n', m, c, d, data.name);

fprintf(fid, '#include "%s.h"\n',  data.fkt);
fprintf(fid, '#include <cvodes/cvodes.h>\n');    
fprintf(fid, '#include <cvodes/cvodes_dense.h>\n');
fprintf(fid, '#include <nvector/nvector_serial.h>\n');
fprintf(fid, '#include <sundials/sundials_types.h>\n'); 
fprintf(fid, '#include <sundials/sundials_math.h>\n');  
fprintf(fid, '#include <udata.h>\n');
fprintf(fid, '#include <math.h>\n');
fprintf(fid, '#include <mex.h>\n');
fprintf(fid, '#include <arInputFunctionsC.h>\n');
fprintf(fid,'\n\n\n');

% write y
fprintf(fid, ' void fy_%s(double t, int nt, int it, int ntlink, int itlink, int ny, int nx, int iruns, double *y, double *p, double *u, double *x){\n', data.fkt);
writeCcode(fid, data, 'fy');
fprintf(fid, '\n  return;\n}\n\n\n');

% write ystd
fprintf(fid, ' void fystd_%s(double t, int nt, int it, int ntlink, int itlink, double *ystd, double *y, double *p, double *u, double *x){\n', data.fkt);
writeCcode(fid, data, 'fystd');
fprintf(fid, '\n  return;\n}\n\n\n');

% write sy
fprintf(fid, ' void fsy_%s(double t, int nt, int it, int ntlink, int itlink, double *sy, double *p, double *u, double *x, double *su, double *sx){\n', data.fkt);
if(config.useSensis)
    writeCcode(fid, data, 'fsy');
end
fprintf(fid, '\n  return;\n}\n\n\n');

% write systd
fprintf(fid, ' void fsystd_%s(double t, int nt, int it, int ntlink, int itlink, double *systd, double *p, double *y, double *u, double *x, double *sy, double *su, double *sx){\n', data.fkt);
if(config.useSensis)
    writeCcode(fid, data, 'fsystd');
end
fprintf(fid, '\n  return;\n}\n\n\n');


% write C code
function writeCcode(fid, cond_data, svar, ip)

if(strcmp(svar,'fv'))
    cstr = ccode(cond_data.sym.fv(:));
    cvar =  'data->v';
elseif(strcmp(svar,'dvdx'))
    cstr = ccode(cond_data.sym.dfvdx(:));
    cvar =  'data->dvdx';
elseif(strcmp(svar,'dvdu'))
    cstr = ccode(cond_data.sym.dfvdu(:));
    cvar =  'data->dvdu';
elseif(strcmp(svar,'dvdp'))
    cstr = ccode(cond_data.sym.dfvdp(:));
    cvar =  'data->dvdp';
elseif(strcmp(svar,'fx'))
    cstr = ccode(cond_data.sym.fx(:));
    for j=find(cond_data.sym.fx(:)' == 0)
        cstr = [cstr sprintf('\n  T[%i][0] = 0.0;',j-1)]; %#ok<AGROW>
    end
    cvar =  'xdot_tmp';
elseif(strcmp(svar,'fx0'))
    cstr = ccode(cond_data.sym.fpx0(:));
    cvar =  'x0_tmp';
elseif(strcmp(svar,'dfxdx'))
    cstr = ccode(cond_data.sym.dfxdx(:));
%     for j=find(cond_data.sym.dfxdx(:)' == 0)
%         cstr = [cstr sprintf('\n  T[%i][0] = 0.0;',j-1)]; %#ok<AGROW>
%     end
    cvar =  'J->data';
elseif(strcmp(svar,'fsv1'))
    cstr = ccode(cond_data.sym.fsv1);
    cvar =  'sv';
elseif(strcmp(svar,'fsv2'))
    cstr = ccode(cond_data.sym.dvdp(:,ip));
    cvar =  '    sv';
elseif(strcmp(svar,'fsx'))
    cstr = ccode(cond_data.sym.fsx);
    for j=find(cond_data.sym.fsx' == 0)
        cstr = [cstr sprintf('\n  T[%i][0] = 0.0;',j-1)]; %#ok<AGROW>
    end
    cvar =  'sxdot_tmp';
elseif(strcmp(svar,'fsx0'))
    cstr = ccode(cond_data.sym.fsx0(:,ip));
    cvar =  '    sx0_tmp';
elseif(strcmp(svar,'fu'))
    cstr = ccode(cond_data.sym.fu(:));
    cvar =  'data->u';
elseif(strcmp(svar,'fsu'))
    cstr = ccode(cond_data.sym.dfudp(:));
    cvar =  'data->su';
elseif(strcmp(svar,'fy'))
    cstr = ccode(cond_data.sym.fy(:));
    cvar =  'y';
elseif(strcmp(svar,'fystd'))
    cstr = ccode(cond_data.sym.fystd(:));
    cvar =  'ystd';
elseif(strcmp(svar,'fsy'))
    cstr = ccode(cond_data.sym.fsy(:));
    cvar =  'sy';
elseif(strcmp(svar,'fsystd'))
    cstr = ccode(cond_data.sym.fsystd(:));
    cvar =  'systd';
elseif(strcmp(svar,'dfxdp'))
    cstr = ccode(cond_data.sym.dfxdp(:));
    cvar =  'dfxdp';
end

cstr = strrep(cstr, 't0', [cvar '[0]']);
cstr = strrep(cstr, '][0]', ']');
cstr = strrep(cstr, 'T', cvar);

if(strcmp(svar,'fsv1'))
    cstr = strrep(cstr, 'su[', sprintf('su[(ip*%i)+',length(cond_data.sym.su)));
end
if(strcmp(svar,'fsv2'))
    cstr = strrep(cstr, '=', '+=');
end

% % debug
% fprintf('\n\n');
% if(config.isMaple)
%     for j=1:length(cstr)
%         fprintf('%s\n', cstr{j});
%     end
% else
%     fprintf('%s', cstr);
% end
% fprintf('\n');

if(~(length(cstr)==1 && isempty(cstr{1})))
	if(strcmp(svar,'fy') || strcmp(svar,'fystd') || strcmp(svar,'fsy') || strcmp(svar,'fsystd'))
        if(strcmp(svar,'fy'))
            cstr = strrep(cstr, 'x[', 'x[nx*ntlink*iruns+itlink+ntlink*');
            cstr = strrep(cstr, 'y[', 'y[ny*nt*iruns+it+nt*');
        else
            cstr = strrep(cstr, 'x[', 'x[itlink+ntlink*');
            cstr = strrep(cstr, 'y[', 'y[it+nt*');
        end
		cstr = strrep(cstr, 'u[', 'u[itlink+ntlink*');
		cstr = strrep(cstr, 'ystd[', 'ystd[it+nt*');
	else
		cstr = strrep(cstr, 'x[', 'x_tmp[');
		cstr = strrep(cstr, 'dvdx_tmp', 'dvdx');
	end
end

fprintf(fid, '%s\n', cstr);

% % debug
% fprintf('\n\n%s\n', cstr);


function writeSimuCalcFunctions(debug_mode)

global ar

% Functions
fid = fopen(['./Compiled/' ar.info.c_version_code '/arSimuCalcFunctions.c'], 'W');

for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        if(~debug_mode)
            fprintf(fid, '#include "%s.h"\n', ar.model(m).condition(c).fkt);
        else
            fprintf(fid, '#include "%s.c"\n', ar.model(m).condition(c).fkt);
        end
    end
    
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            if(~debug_mode)
                fprintf(fid, '#include "%s.h"\n', ar.model(m).data(d).fkt);
            else
                fprintf(fid, '#include "%s.c"\n', ar.model(m).data(d).fkt);
            end
        end
    end
end
fprintf(fid, '\n');

% map CVodeInit to fx
fprintf(fid, ' int AR_CVodeInit(void *cvode_mem, N_Vector x, double t, int im, int ic){\n');
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '  if(im==%i & ic==%i) return CVodeInit(cvode_mem, fx_%s, RCONST(t), x);\n', ...
            m-1, c-1, ar.model(m).condition(c).fkt);
    end
end
fprintf(fid, '  return(-1);\n');
fprintf(fid, '}\n\n');

% map fx
fprintf(fid, ' void fx(realtype t, N_Vector x, double *xdot, void *user_data, int im, int ic){\n');
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '  if(im==%i & ic==%i) fxdouble_%s(t, x, xdot, user_data);\n', ...
            m-1, c-1, ar.model(m).condition(c).fkt);
    end
end
fprintf(fid, '}\n\n');

% map fx0
fprintf(fid, ' void fx0(N_Vector x0, void *user_data, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '  if(im==%i & ic==%i) fx0_%s(x0, data);\n', ...
            m-1, c-1, ar.model(m).condition(c).fkt);
    end
end
fprintf(fid, '}\n\n');

% map CVDlsSetDenseJacFn to dfxdx
fprintf(fid, ' int AR_CVDlsSetDenseJacFn(void *cvode_mem, int im, int ic){\n');
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '  if(im==%i & ic==%i) return CVDlsSetDenseJacFn(cvode_mem, dfxdx_%s);\n', ...
            m-1, c-1, ar.model(m).condition(c).fkt);
    end
end
fprintf(fid, '  return(-1);\n');
fprintf(fid, '}\n\n');

% map fsx0
fprintf(fid, ' void fsx0(int is, N_Vector sx_is, void *user_data, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '  if(im==%i & ic==%i) fsx0_%s(is, sx_is, data);\n', ...
            m-1, c-1, ar.model(m).condition(c).fkt);
    end
end
fprintf(fid, '}\n\n');

% map CVodeSensInit1 to fsx
fprintf(fid, ' int AR_CVodeSensInit1(void *cvode_mem, int nps, int sensi_meth, int sensirhs, N_Vector *sx, int im, int ic){\n');
if(ar.config.useSensiRHS)
    fprintf(fid, '  if (sensirhs == 1) {\n');
    for m=1:length(ar.model)
        for c=1:length(ar.model(m).condition)
            fprintf(fid, '    if(im==%i & ic==%i) return CVodeSensInit1(cvode_mem, nps, sensi_meth, fsx_%s, sx);\n', ...
                m-1, c-1, ar.model(m).condition(c).fkt);
        end
    end
    fprintf(fid, '  } else {\n');
end
for m=1:length(ar.model)
    for c=1:length(ar.model(m).condition)
        fprintf(fid, '    if(im==%i & ic==%i) return CVodeSensInit1(cvode_mem, nps, sensi_meth, NULL, sx);\n', ...
            m-1, c-1);
    end
end
if(ar.config.useSensiRHS)
    fprintf(fid, '  }\n');
end
fprintf(fid, '  return(-1);\n');
fprintf(fid, '}\n\n');

% map fu
fprintf(fid, ' void fu(void *user_data, double t, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) fu_%s(data, t);\n', ...
			m-1, c-1, ar.model(m).condition(c).fkt);
	end
end
fprintf(fid, '}\n\n');

% map fsu
fprintf(fid, ' void fsu(void *user_data, double t, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) fsu_%s(data, t);\n', ...
			m-1, c-1, ar.model(m).condition(c).fkt);
	end
end
fprintf(fid, '}\n\n');

% map fv
fprintf(fid, ' void fv(void *user_data, double t, N_Vector x, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) fv_%s(t, x, data);\n', ...
			m-1, c-1, ar.model(m).condition(c).fkt);
	end
end
fprintf(fid, '}\n\n');

% map fsv
fprintf(fid, ' void fsv(void *user_data, double t, N_Vector x, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) {\n\tdvdp_%s(t, x, data);\n\tdvdu_%s(t, x, data);\n\tdvdx_%s(t, x, data);\n}\n', ...
			m-1, c-1, ar.model(m).condition(c).fkt, ar.model(m).condition(c).fkt, ar.model(m).condition(c).fkt);
	end
end
fprintf(fid, '}\n\n');

% map dfxdp
fprintf(fid, ' void dfxdp(void *user_data, double t, N_Vector x, double *dfxdp, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) dfxdp_%s(t, x, dfxdp, data);\n', ...
			m-1, c-1, ar.model(m).condition(c).fkt);
	end
end
fprintf(fid, '}\n\n');

% map fy
fprintf(fid, ' void fy(double t, int nt, int it, int ntlink, int itlink, int ny, int nx, int iruns, double *y, double *p, double *u, double *x, int im, int id){\n');
for m=1:length(ar.model)
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            fprintf(fid, '  if(im==%i & id==%i) fy_%s(t, nt, it, ntlink, itlink, ny, nx, iruns, y, p, u, x);\n', ...
                m-1, d-1, ar.model(m).data(d).fkt);
        end
    end
end
fprintf(fid, '}\n\n');

% map fystd
fprintf(fid, ' void fystd(double t, int nt, int it, int ntlink, int itlink, double *ystd, double *y, double *p, double *u, double *x, int im, int id){\n');
for m=1:length(ar.model)
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            fprintf(fid, '  if(im==%i & id==%i) fystd_%s(t, nt, it, ntlink, itlink, ystd, y, p, u, x);\n', ...
                m-1, d-1, ar.model(m).data(d).fkt);
        end
    end
end
fprintf(fid, '}\n\n');

% map fsy
fprintf(fid, ' void fsy(double t, int nt, int it, int ntlink, int itlink, double *sy, double *p, double *u, double *x, double *su, double *sx, int im, int id){\n');
for m=1:length(ar.model)
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            fprintf(fid, '  if(im==%i & id==%i) fsy_%s(t, nt, it, ntlink, itlink, sy, p, u, x, su, sx);\n', ...
                m-1, d-1, ar.model(m).data(d).fkt);
        end
    end
end
fprintf(fid, '}\n\n');

% map fsystd
fprintf(fid, ' void fsystd(double t, int nt, int it, int ntlink, int itlink, double *systd, double *p, double *y, double *u, double *x, double *sy, double *su, double *sx, int im, int id){\n');
for m=1:length(ar.model)
    if(isfield(ar.model(m), 'data'))
        for d=1:length(ar.model(m).data)
            fprintf(fid, '  if(im==%i & id==%i) fsystd_%s(t, nt, it, ntlink, itlink, systd, p, y, u, x, sy, su, sx);\n', ...
                m-1, d-1, ar.model(m).data(d).fkt);
        end
    end
end
fprintf(fid, '}\n\n');

% for arSSACalc
% call to fu and fv
fprintf(fid, '/* for arSSACalc.c */\n\n');
fprintf(fid, ' void fvSSA(void *user_data, double t, N_Vector x, int im, int ic){\n');
fprintf(fid, '  UserData data = (UserData) user_data;\n');
for m=1:length(ar.model)
	for c=1:length(ar.model(m).condition)
		fprintf(fid, '  if(im==%i & ic==%i) {\n', m-1, c-1);
        fprintf(fid, '    fu_%s(data, t);\n', ar.model(m).condition(c).fkt);
        fprintf(fid, '    fv_%s(t, x, data);\n', ar.model(m).condition(c).fkt);
        fprintf(fid, '  }\n');
	end
end
fprintf(fid, '}\n\n');

fclose(fid);
