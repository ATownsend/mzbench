import React from 'react';
import MZBenchRouter from '../utils/MZBenchRouter';
import MZBenchActions from '../actions/MZBenchActions';
import moment from 'moment';
import 'moment-duration-format';
import BenchStore from '../stores/BenchStore';
import TagInput from 'react-categorized-tag-input';
import AuthStore from '../stores/AuthStore';

class BenchSummary extends React.Component {
    constructor(props) {
        super(props);

        this.state = { tags: props.bench.tags};
    }

    _labelCssClass(status) {
        switch (status) {
            case "complete":
                return "label-success";
            case "failed":
                return "label-danger";
            case "zombie":
                return "label-warning";
            case "stopped":
                return "label-default";
        }
        return "label-info";
    }

    componentWillReceiveProps(newProps) {
        let newTags = newProps.bench.tags;
        let oldTags = this.state.tags;
        if (!newTags.every((e) => {oldTags.indexOf(e) > -1}) ||
            !oldTags.every((e) => {newTags.indexOf(e) > -1})) {
            this.setState({tags: newProps.bench.tags.slice()})
        }
    }

    render() {
        let bench = this.props.bench;

        let labelClass = this._labelCssClass(bench.status);

        var tagSuggestions = BenchStore.getAllTags();
        this.state.tags.reduce(
            (acc, t) => {
                var i = acc.indexOf(t);
                if (i > -1) acc.splice(i, 1);
                return acc;
            }, tagSuggestions);

        var tags = this.state.tags.slice().map((t) => {return {title: t, category: 'cat1'};});

        var canStop = AuthStore.isAnonymousServer() ||
                      (this.props.bench.author == AuthStore.userLogin());

        return (
            <div className="fluid-container">
                <div className="row bench-details">
                    <div className="row col-xs-9">
                        <div className="col-xs-12 col-md-12">
                            <div className="row">
                                <div className="col-xs-4 col-md-2 bench-details-key bench-details-hd">Scenario</div>
                                <div className="col-xs-8 col-md-10 bench-details-hd">#{bench.id} {bench.name}</div>
                            </div>
                        </div>
                        <div className="col-xs-12 col-md-6">
                            <div className="row">
                                <div className="col-xs-4 bench-details-key bench-details-el">Author</div>
                                <div className="col-xs-8 bench-details-el">{bench.author}</div>
                            </div>
                        </div>
                        <div className="col-xs-12 col-md-6">
                            <div className="row">
                                <div className="col-xs-4 bench-details-key bench-details-el">Cloud</div>
                                <div className="col-xs-8 bench-details-el">{bench.cloud}, {bench.nodes} node(s)</div>
                            </div>
                        </div>
                        {bench.exclusive != "" ?
                            <div className="col-xs-12 col-md-6">
                                <div className="row">
                                    <div className="col-xs-4 bench-details-key bench-details-el">Exclusive label</div>
                                    <div className="col-xs-8 bench-details-el">{bench.exclusive}</div>
                                </div>
                            </div>: null}
                        <div className="col-xs-12 col-md-6">
                            <div className="row">
                                <div className="col-xs-4 bench-details-key bench-details-el">Duration</div>
                                <div className="col-xs-8 bench-details-el">{moment.duration(this.props.duration).format("h [hrs], m [min], s [sec]")}</div>
                            </div>
                        </div>
                        <div className="col-xs-12 col-md-6">
                            <div className="row">
                                <div className="col-xs-4 bench-details-key bench-details-el">Date</div>
                                <div className="col-xs-8 bench-details-el">{bench.start_time_client.format("lll")}</div>
                            </div>
                        </div>
                        <div className="col-xs-12 col-md-6">
                            <div className="row">
                                <div className="col-xs-4 bench-details-key bench-details-el">Status</div>
                                <div className="col-xs-8 bench-details-el"><span className={`label ${labelClass}`}>{bench.status}</span></div>
                            </div>
                        </div>
                        {bench.parent != "undefined" ?
                            <div className="col-xs-12 col-md-6">
                                <div className="row">
                                    <div className="col-xs-4 bench-details-key bench-details-el">Parent</div>
                                    <div className="col-xs-8 bench-details-el"><a href={`#/bench/${bench.parent}/overview`}>#{bench.parent}</a></div>
                                </div>
                            </div> : null}
                        <div className="col-xs-12 col-md-12">
                            <div className="row">
                                <div className="col-xs-4 col-md-2 bench-details-key bench-details-el">Tags</div>
                                <div className="col-xs-8 col-md-10 bench-details-el">
                                    <TagInput value={tags}
                                              categories={[{
                                                        id: 'cat1', type: 'tag',
                                                        title: 'existing tags',
                                                        items: tagSuggestions.slice(),
                                                        single: false
                                                      }]}
                                              addNew={true}
                                              transformTag={(tag) => {return tag.title;}}
                                              onChange={this._handleTagChange.bind(this)}
                                              placeholder="Add a tag"
                                              />
                                </div>
                            </div>
                        </div>
                    </div>

                    <div className="bench-actions col-xs-3">
                        <div className="text-right">
                            <a type="button" data-msg="stopped" className="btn btn-sm btn-danger" href={MZBenchRouter.buildLink("/stop", {id: this.props.bench.id})}
                                    disabled={!this.props.bench.isRunning() || !canStop} onClick={this._onClick}>
                                <span className="glyphicon glyphicon-minus-sign"></span> Stop
                            </a>
                        </div>
                        <div className="text-right">
                            <div className="btn-group">
                                <a data-msg="restarted" className="btn btn-sm btn-primary pre-dropdown" href={MZBenchRouter.buildLink("/restart", {id: this.props.bench.id})}
                                        disabled={this.props.bench.isRunning()} onClick={this._onClick}>
                                    <span className="glyphicon glyphicon-refresh"></span> Restart
                                </a>
                                <button className="btn btn-primary dropdown-toggle" data-toggle="dropdown" aria-haspopup="true" aria-expanded="false">
                                    <span className="caret"></span>
                                </button>
                                <ul className="dropdown-menu">
                                    <li><a href="#" onClick={this._onCloneBench} data-id={this.props.bench.id}>Clone</a></li>
                                </ul>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        );
    }

    _handleTagChange(tags) {
        var new_tags = tags.map((t) => {return t.title;});
        var old_tags = this.state.tags;
        this.setState({tags: new_tags});
        new_tags.map((t) => {
            if (old_tags.indexOf(t) == -1) {
                MZBenchActions.addBenchTag(this.props.bench.id, t);
            }
        });

        old_tags.map((t) => {
            if (new_tags.indexOf(t) == -1) {
                MZBenchActions.removeBenchTag(this.props.bench.id, t);
            }
        });
    }

    _onCloneBench(event) {
        event.preventDefault();
        MZBenchActions.cloneBench(parseInt($(event.target).data("id")));
        MZBenchRouter.navigate("#/new", {});
    }

    _onClick(event) {
        event.preventDefault();

        let anchor = $(event.target).closest('a');
        let action_message = 'Benchmark ' + anchor.data('msg');
        if (!anchor.attr('disabled')) {
            $.ajax({url: anchor.attr('href'),
                    success: () => {$.notify({message: action_message}, {type: 'success', delay: 3000});},
                    error: () => {$.notify({message: 'Request failed'}, {type: 'danger', delay: 3000});},
                    beforeSend: function (xhr) {
                        if (AuthStore.getToken()) {
                            xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.getToken() );
                        }
                    }
                });
        }
    }
};

BenchSummary.propTypes = {
    bench: React.PropTypes.object.isRequired
};

export default BenchSummary;
