import {connect} from 'react-redux'  
import { fetchDBStates,fetchDBStatesSuccess, fetchDBStatesFailure } from '../actions'
import { getDBStatesSorted } from '../reducers/index'
import DBStates from './DBStates'


const mapStateToProps = (state) => {
  return {
    rows: getDBStatesSorted(state),
    loading: state.postgres.dbstates.loading,
    error: state.postgres.dbstates.error
  }
}

const mapDispatchToProps = (dispatch,state) => {
  return {
    fetchDBStates: () => {
      dispatch(fetchDBStates())
    },
    fetchDBStatesSuccess: (rows) => {
      dispatch(fetchDBStatesSuccess(rows))
    },
    fetchDBStatesFailure: (error) => {
      dispatch(fetchDBStatesFailure(error))
    }}
}

const DBStatesContainer = connect(
  mapStateToProps,
  mapDispatchToProps
)(DBStates)


export default DBStatesContainer
