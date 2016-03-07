import os
import re
import uuid
import time
import copy
from threading import Thread
from flask import Flask, jsonify, render_template, request, session, Markup
from simplejson import JSONEncoder
import pyd2d

__author__ = 'Clemens Blank'
app = Flask(__name__)

try:
    from flask.ext.compress import Compress
    app.config['COMPRESS_LEVEL'] = 4
    Compress(app)
except:
    pass

FIELDS = {
    'pLabel', 'p', 'lb', 'ub', 'chi2fit', 'config.optim.MaxIter',
    'config.nFinePoints', 'model.u', 'model.pu', 'model.py', 'model.pc',
    'model.pystd', 'model.pv', 'model.pcond', 'model.fu',
    'model.name', 'model.xNames', 'model.z', 'model.description',
    'model.condition.tFine', 'model.condition.uFineSimu',
    'model.data.yNames', 'model.data.tFine', 'model.data.tExp',
    'model.data.yFineSimu', 'model.data.ystdFineSimu', 'model.data.yExp',
    'model.data.yExpStd', 'model.condition.xFineSimu',
    'model.condition.zFineSimu'
}

FIELDS_FIT = {
    'fit.iter', 'fit.iter_count', 'fit.improve', 'fit.chi2_hist',
    'fit.p_hist'
}

SESSION_LIFETIME = 3000
DEBUG = True

d2d_instances = {}


@app.before_request
def before_request():

    # create session
    if not session.get('uid'):
        session.permanent = True
        session['uid'] = uuid.uuid4()

    # update instance lifetime on any activity
    elif session.get('uid') in d2d_instances:
        d2d_instances[session.get('uid')]['alive'] = 1


@app.route('/_filetree', methods=['GET'])
def filetree():
    tree = create_filetree(path=os.path.join(os.getcwd(), 'models'),
                           max_depth=2)
    return jsonify(tree=tree)


@app.route('/', methods=['GET'])
@app.route('/d2d_presenter', methods=['GET'])
def d2d_presenter():

    return render_template('d2d_presenter.html')


@app.route('/_start', methods=['GET'])
def start():

    ROUND = int(request.args.get('round'))
    if ROUND is 0:
        ROUND = False

    status = {}
    status['nFinePoints_min'] = False
    status['arSimu'] = False

    nFinePoints = int(request.args.get('nFinePoints'))
    do_compile = str(request.args.get('compile'))

    d2d_instances.update(
        {
            session['uid']: {'d2d': pyd2d.d2d(), 'alive': 1,
                             'model': os.path.join(
                                os.getcwd(),
                                request.args.get('model')),
                             'nFinePoints': nFinePoints,
                             'ROUND': ROUND,
                             'MODEL': 1,
                             'DSET': 1
                             }
        })

    if do_compile.endswith('on'):
        load = False
    else:
        try:
            results = os.listdir(os.path.join(
                os.path.dirname(d2d_instances[session['uid']]['model']),
                'results'))

            for savename in results:
                if savename.endswith('_d2d_presenter'):
                    load = savename
                    break
        except:
            print("No saved results found for d2d_presenter, compiling from " +
                  "scratch. This might take some time.")

    d2d_instances[session['uid']]['d2d'].load_model(
        d2d_instances[session['uid']]['model'], load=load)

    try:
        nFinePoints_min = d2d_instances[session['uid']]['d2d'].get(
            {'d2d_presenter.nFinePoints_min'},
            1, 1, False, 'list')['d2d_presenter.nFinePoints_min'][0][0]
    except:
        nFinePoints_min = nFinePoints

    if nFinePoints_min > nFinePoints:
        nFinePoints = nFinePoints_min
        status['nFinePoints_min'] = nFinePoints

    d2d_instances[session['uid']]['d2d'].set(
        {'ar.config.nFinePoints': nFinePoints})
    d2d_instances[session['uid']]['d2d'].eval("arLink;")
    status['arSimu'] = d2d_instances[session['uid']]['d2d'].simu()
    d2d_instances[session['uid']]['d2d'].eval("arChi2;")

    # thread will shut down the matlab instance on inactivity
    t = Thread(target=d2d_close_instance, args=(session['uid'], ))
    t.start()

    return jsonify(status=status)


@app.route('/_update', methods=['GET'])
def update():

    if not session['uid'] in d2d_instances:
        return jsonify(session_expired=True)

    data = {}
    extra = {}
    status = {}

    d2d = d2d_instances[session['uid']]['d2d']

    if (request.args.get('filename') is None or
            request.args.get('filename') == "" or
            request.args.get('filename') == 'undefined'):
        extra['filename'] = os.path.join(
            d2d.path.replace(os.getcwd() +
                             os.path.sep, ''), d2d.filename)
    else:
        extra['filename'] = request.args.get('filename')

    options = request.args.get('options').split(';')

    if 'console' in options:
        command = request.args.get('command')
        d2d.eval(command)

        extra['console'] = d2d.output_total

    if 'setup' in options:
        d2d.load_model(d2d_instances[session['uid']]['model'], load=False)

    if 'change_mdc' in options:

        if request.args.get('name') == 'MODEL':
            d2d_instances[session['uid']]['MODEL'] =\
                int(request.args.get('value'))
        elif request.args.get('name') == 'DSET':
            d2d_instances[session['uid']]['DSET'] =\
                int(request.args.get('value'))

    if 'simu_data' in options:
        status['arSimu'] = d2d.simu('false', 'false', 'false')
        status['arSimuData'] = d2d.eval(
            'arSimuData(' +
            str(d2d_instances[session['uid']]['MODEL']) + ',' +
            str(d2d_instances[session['uid']]['DSET']) + ');'
        )
        d2d.eval('arChi2;')

    if 'model' in options:
        try:
            extra['svg'] = Markup(
                editor('read', os.path.join(
                        d2d.path, 'Models',
                        d2d.get(
                            {'model.name'},
                            d2d_instances[session['uid']]['MODEL'],
                            d2d_instances[session['uid']]['DSET']
                        )['model.name'] + '.svg'))['content'])
        except:
            extra['svg'] = ''

        extra['size'] = {}

        try:
            extra['MODEL'] = d2d_instances[session['uid']]['MODEL']
            extra['size']['MODEL'] = d2d.eval('length(ar.model)', 1)
            extra['size']['MODELNAMES'] = []

            for i in range(int(extra['size']['MODEL'])):
                extra['size']['MODELNAMES'].append(d2d.get(
                    {'model.name'},
                    i+1,
                    d2d_instances[session['uid']]['DSET'], False, 'list'
                )['model.name'])
        except:
            pass
        try:
            extra['DSET'] = d2d_instances[session['uid']]['DSET']
            extra['size']['DSET'] = d2d.eval(
                "length(ar.model(" +
                str(d2d_instances[session['uid']]['MODEL']) +
                ").plot)", 1)
            extra['size'].update(d2d.get(
                    {'model.plot.name'},
                    d2d_instances[session['uid']]['MODEL'],
                    d2d_instances[session['uid']]['DSET'], False, 'list'
                ))
        except:
            pass

    if 'max_iter' in options:
        max_iter = int(request.args.get('max_iter'))
        d2d.set({'ar.config.optim.MaxIter': max_iter})

    if 'fit' in options:
        d2d.eval("arFit")

    if 'tree' in options:
        extra['tree'] = create_filetree(path=d2d.path)

    if 'read' in options:
        extra['editor_data'] = editor('read', extra['filename'])

    if 'write' in options:
        extra['editor_data'] = editor('write', extra['filename'],
                                      request.args.get('content'))

    if 'update_graphs' in options:  # set new parameters
        d2d.set_pars_from_dict(request.args.to_dict())

    if 'chi2' in options:
        status['arSimu'] = d2d.simu()
        d2d.eval("arChi2")

    if 'update_graphs' in options or 'create_graphs' in options:
        status['arSimu'] = d2d.simu('false', 'true', 'false')
        data = select_data(d2d_instances[session['uid']], options)

        data = create_dygraphs_data(data)

        d2d_instances[session['uid']]['data'] = data

    return jsonify(ar=data, extra=extra, status=status)


@app.route('/_console', methods=['GET'])
def console():
    if not session['uid'] in d2d_instances:
        return jsonify(session_expired=True)

    if request.args.get('command') != '':
        command = request.args.get('command')
        d2d_instances[session['uid']]['d2d'].eval(command)

    console = d2d_instances[session['uid']]['d2d'].output_total

    return jsonify(console=console)


def select_data(d2d_instance, options):
    """Reads out the specified ar fields.
    MODEL set's the model from which to select the data.
    DSET set's the dataset from which to select the data.
    ROUND specifies how many significant digit should be respected (in order
    to decrease the amount of data sent to the client), however it comes at
    the cost of some ms (e.g. 10ms in Raia_CancerResearch2011 on medium
    hardware).
    'list' can be used to get python lists, 'numpy' to get numpy array (2ms
    faster).
    If option 'fit' is set, also the fields in FIELDS_FIT will be respected.
    """
    global FIELDS, FIELDS_FIT

    if 'fit' in options:
        fields = FIELDS.copy()
        fields.update(FIELDS_FIT)
    else:
        fields = FIELDS

    return d2d_instance['d2d'].get(fields, d2d_instance['MODEL'],
                                   d2d_instance['DSET'],
                                   d2d_instance['ROUND'], 'list')


def create_dygraphs_data(data):
    """Converts the data for use in dygraphs.js

    Errors need to be set to 0 if not available.
    """
    # make sure there are no two data entries with same timestamp, and if so
    # add epsilon to it, since dygraphs might get confused
    # for j in range(len(data['model.data.tExp'])):
    #     for i, key in enumerate(data['model.data.tExp'][j][0]):
    #         while (data['model.data.tExp'][j][0][i] in
    #                data['model.data.tFine'][j][0]):
    #             print(data['model.data.tExp'][j][0][i])
    #             data['model.data.tExp'][j][0][i] =\
    #              data['model.data.tExp'][j][0][i] + sys.float_info.epsilon

    data['plots'] = {}
    data['plots']['observables'] = []

    if data['model.data.yNames'][0]:

        tObs = data['model.data.tFine'][0][0].copy()

        if data['model.data.tExp'][0]:
            for i in range(len(data['model.data.tExp'])):
                tObs = tObs + data['model.data.tExp'][i][0].copy()
        tObs = [[x] for x in tObs]

        for i in range(len(data['model.data.yNames'][0])):
            data['plots']['observables'].append(copy.deepcopy(tObs))
            for k in range(len(data['model.data.tFine'])):
                for j in range(len(data['model.data.tFine'][k][0])):
                    data['plots']['observables'][i][j].append([
                        data['model.data.yFineSimu'][k][i][j],
                        data['model.data.ystdFineSimu'][k][i][j]])
                    data['plots']['observables'][i][j].append(
                        [float('nan'), 0])

            if data['model.data.tExp'][0]:
                c = len(data['model.data.tFine'][0][0])
                for k in range(len(data['model.data.tExp'])):
                    for j in range(len(data['model.data.tExp'][k][0])):
                        for l in range(len(data['model.data.tExp'])):
                            data['plots']['observables'][i][c].append(
                                [float('nan'), float('nan')])
                            if l is k:
                                data['plots']['observables'][i][c].append(
                                    [data['model.data.yExp'][l][i][j],
                                        data['model.data.yExpStd'][l][i][j]])
                            else:
                                data['plots']['observables'][i][c].append(
                                    [float('nan'), float('nan')])
                        c = c + 1

            data['plots']['observables'][i].sort(key=lambda x: x[0])

    if len(data['model.z']) > 0:

        data['model.xNames'] = data['model.xNames'] + data['model.z']

        xzFine = []

        for i in range(len(data['model.condition.xFineSimu'])):

            xzFine.append(([data['model.condition.xFineSimu'][i] +
                          data['model.condition.zFineSimu'][i]])[0])

        data['model.condition.xFineSimu'] = xzFine

    data['plots']['variables'] = []

    for i in range(len(data['model.xNames'])):
        data['plots']['variables'].append(
            data['model.condition.tFine'][0][0].copy())
        for j in range(len(data['model.condition.tFine'][0][0])):
            data['plots']['variables'][i][j] =\
                [data['plots']['variables'][i][j]]
            for k in range(len(data['model.condition.xFineSimu'])):
                data['plots']['variables'][i][j].append(
                    data['model.condition.xFineSimu'][k][i][j])

    data['plots']['inputs'] = []

    if len(data['model.u']) > 0:
        if isinstance(data['model.u'][0], str):
            data['model.condition.uFineSimu'] =\
                [data['model.condition.uFineSimu']]

        for i in range(len(data['model.u'])):
            data['plots']['inputs'].append(
                data['model.condition.tFine'][0][0].copy())
            for j in range(len(data['model.condition.tFine'][0][0])):
                data['plots']['inputs'][i][j] = [data['plots']['inputs'][i][j]]
                data['plots']['inputs'][i][j].append(
                    data['model.condition.uFineSimu'][0][0][i][j])

    # remove unecessary data to lower the traffic
    data.pop('model.data.tFine', None)
    data.pop('model.data.yFineSimu', None)
    data.pop('model.data.ystdFineSimu', None)
    data.pop('model.data.tExp', None)
    data.pop('model.data.yExp', None)
    data.pop('model.data.yExpStd', None)
    data.pop('model.condition.tFine', None)
    data.pop('model.condition.uFineSimu', None)
    data.pop('model.condition.xFineSimu', None)
    data.pop('model.condition.zFineSimu', None)
    data.pop('model.condition.z', None)
    data.pop('model.z', None)

    # remove spaces (spaces wont work in css/html ids)
    try:
        for i, key in enumerate(data['model.xNames']):
            data['model.xNames'][i] = key.replace(
                ' ', '_').replace('(', '').replace(')', '')
    except:
        pass
    try:
        for i, key in enumerate(data['model.u']):
            data['model.u'][i] = key.replace(
                ' ', '_').replace('(', '').replace(')', '')
    except:
        pass
    try:
        for i, key in enumerate(data['model.data.yNames'][0]):
            data['model.data.yNames'][0][i] = key.replace(
                ' ', '_').replace('(', '').replace(')', '')
    except:
        pass

    return data


def editor(option, filename, content=None):

    file_content = {}

    if option == 'read':
        try:
            file = open(filename, 'r')
            file_content = {"content": file.read()}
            file.close()
        except:
            print("Couldn't read file.")

    elif option == 'write':

        try:
            file = open(filename, 'w')
            file.write(content)
            file.close()
            file_content = {"content": content}

        except:
            print("Couldn't write file.")

    return file_content


def create_filetree(path=None, depth=0, max_depth=0):

    tree = None

    if max_depth == 0 or depth < max_depth:
        if path is None:
            path = os.getcwd()

        tree = dict(name=os.path.basename(path), children=[])

        try:
            lst = os.listdir(path)
        except OSError:
            pass  # ignore errors
        else:
            for name in lst:
                fn = os.path.join(path, name)
                if (
                    os.path.isdir(fn) and re.match('^.*(Compiled)$', fn)
                    is None
                ):
                    child = create_filetree(fn, depth + 1, max_depth)
                    if child is not None:
                        tree['children'].append(child)
                elif re.match('^.*\.(m|def|txt|csv)$', fn) is not None:
                    tree['children'].append(dict(name=fn.replace(
                        os.getcwd() + os.path.sep, "")))

    return tree


def d2d_close_instance(uid):
    """Shut's down the d2d instance and thread."""
    while True:
        try:
            if d2d_instances[uid]['alive'] == 0:
                # clean up the global dicts, deletes the instances
                del(d2d_instances[uid])
                break

            d2d_instances[uid]['alive'] = 0
            time.sleep(SESSION_LIFETIME)
        except:
            print('Unable to shutdown thread ' + str(uid))
            break


class JSONEncoder_ignore(JSONEncoder):
    """Set the encoder to ignore nan values, which will transfere all 'NaN',
    infinity etc. to "null" - somehing dygraph understands."""
    def __init__(self, **kwargs):
        """Leaves JSONEncoder as it is, just switches "ingore_nan" on."""
        kwargs['ignore_nan'] = True
        super(JSONEncoder_ignore, self).__init__(**kwargs)

if __name__ == "__main__":
    app.secret_key = os.urandom(24)
    app.permanent_session_lifetime = SESSION_LIFETIME
    app.debug = DEBUG
    app.json_encoder = JSONEncoder_ignore
    app.run(threaded=True,
            host="127.0.0.1",
            port=int("5000")
            )