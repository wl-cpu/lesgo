!*********************************************************************
module clocks
!*********************************************************************
!
! This module provides the clock data type (object) and the
! subroutines/functions that act on instances of the clock data type.
!
use types, only : rprec
implicit none

save 
private

public clock_type, &
     clock_start, &
     clock_stop

type clock_type
   real(rprec) :: start
   real(rprec) :: stop
   real(rprec) :: time
end type clock_type

!---------------------------------------------------------------------
contains
!---------------------------------------------------------------------

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine clock_start( this )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
implicit none

type(clock_type), intent(inout) :: this
!integer, dimension(8) :: timevalues

call cpu_time( this % start )
!call MPI_WTIME (this % start )
!call date_and_time(VALUES=timevalues)
!this%start = timevalues(5)*3600+timevalues(6)*60+timevalues(7)+timevalues(8)*0.001
return
end subroutine clock_start

!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
subroutine clock_stop( this )
!+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
implicit none

type(clock_type), intent(inout) :: this
!integer, dimension(8) :: timevalues

call cpu_time( this % stop )
!call MPI_WTIME( this % stop )
!call date_and_time(VALUES=timevalues)
!this%stop = timevalues(5)*3600+timevalues(6)*60+timevalues(7)+timevalues(8)*0.001

! Compute the clock time
this % time = this % stop - this % start

return
end subroutine clock_stop

end module clocks
